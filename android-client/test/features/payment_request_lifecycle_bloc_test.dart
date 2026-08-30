import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_request_lifecycle_bloc.dart';

void main() {
  test(
    'a new request becomes pending before the server reports it paid',
    () async {
      final _Store store = _Store();
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: _Server(const PaymentRequestServerResult.paid()),
        now: () => DateTime.utc(2026, 8, 30, 10),
      );
      final PaymentRequest request = PaymentRequest(
        requestId: 'request-001',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );

      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PaymentRequestPending>(),
          isA<PaymentRequestPaid>(),
        ]),
      );

      bloc.add(PaymentRequestSubmitted(request));
      await states;
      expect(store.value?.status, PaymentRequestStatus.paid);
      await bloc.close();
    },
  );

  test(
    'an already expired request persists expiry without contacting the server',
    () async {
      final _Store store = _Store();
      final _Server server = _Server(const PaymentRequestServerResult.paid());
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: server,
        now: () => DateTime.utc(2026, 8, 30, 10),
      );
      final PaymentRequest request = PaymentRequest(
        requestId: 'request-002',
        expiresAt: DateTime.utc(2026, 8, 30, 10),
      );

      final Future<void> expired = expectLater(
        bloc.stream,
        emits(isA<PaymentRequestExpired>()),
      );
      bloc.add(PaymentRequestSubmitted(request));
      await expired;

      expect(server.calls, 0);
      expect(store.value?.status, PaymentRequestStatus.expired);
      await bloc.close();
    },
  );

  test(
    'retry reloads a pending request and keeps an authoritative pending result',
    () async {
      final PaymentRequest request = PaymentRequest(
        requestId: 'request-003',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );
      final _Store store = _Store()
        ..value = PaymentRequestSnapshot(
          request: request,
          status: PaymentRequestStatus.pending,
        );
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: _Server(const PaymentRequestServerResult.pending()),
        now: () => DateTime.utc(2026, 8, 30, 10),
      );

      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PaymentRequestRetrying>(),
          isA<PaymentRequestPending>(),
        ]),
      );
      bloc.add(PaymentRequestRetryRequested(request));
      await states;
      expect(store.value?.status, PaymentRequestStatus.pending);
      await bloc.close();
    },
  );

  test(
    'retry resolves a durably expired request without contacting the server',
    () async {
      final PaymentRequest request = PaymentRequest(
        requestId: 'request-003a',
        expiresAt: DateTime.utc(2026, 8, 30, 9),
      );
      final _Store store = _Store()
        ..value = PaymentRequestSnapshot(
          request: request,
          status: PaymentRequestStatus.expired,
        );
      final _Server server = _Server(const PaymentRequestServerResult.paid());
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: server,
        now: () => DateTime.utc(2026, 8, 30, 10),
      );

      final Future<void> expired = expectLater(
        bloc.stream,
        emits(isA<PaymentRequestExpired>()),
      );
      bloc.add(PaymentRequestRetryRequested(request));
      await expired;
      expect(server.calls, 0);
      await bloc.close();
    },
  );

  test(
    'serializes rapid submissions so neither payment request is lost',
    () async {
      final _Store store = _Store();
      final _RecordingServer server = _RecordingServer();
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: server,
        now: () => DateTime.utc(2026, 8, 30, 10),
      );
      final PaymentRequest first = PaymentRequest(
        requestId: 'request-003b',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );
      final PaymentRequest second = PaymentRequest(
        requestId: 'request-003c',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );

      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PaymentRequestPending>(),
          isA<PaymentRequestPaid>(),
          isA<PaymentRequestPending>(),
          isA<PaymentRequestPaid>(),
        ]),
      );
      bloc
        ..add(PaymentRequestSubmitted(first))
        ..add(PaymentRequestSubmitted(second));
      await states;

      expect(server.requestIds, <String>['request-003b', 'request-003c']);
      await bloc.close();
    },
  );

  test('an exact duplicate submit cannot downgrade a paid request', () async {
    final PaymentRequest request = PaymentRequest(
      requestId: 'request-003d',
      expiresAt: DateTime.utc(2026, 8, 30, 11),
    );
    final _Store store = _Store()
      ..value = PaymentRequestSnapshot(
        request: request,
        status: PaymentRequestStatus.paid,
      );
    final _Server server = _Server(const PaymentRequestServerResult.pending());
    final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
      store: store,
      server: server,
      now: () => DateTime.utc(2026, 8, 30, 10),
    );

    final Future<void> paid = expectLater(
      bloc.stream,
      emits(isA<PaymentRequestPaid>()),
    );
    bloc.add(PaymentRequestSubmitted(request));
    await paid;

    expect(server.calls, 0);
    expect(store.value?.status, PaymentRequestStatus.paid);
    await bloc.close();
  });

  test(
    'a changed duplicate request cannot replace durable terminal evidence',
    () async {
      final PaymentRequest original = PaymentRequest(
        requestId: 'request-003e',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );
      final _Store store = _Store()
        ..value = PaymentRequestSnapshot(
          request: original,
          status: PaymentRequestStatus.paid,
        );
      final _Server server = _Server(
        const PaymentRequestServerResult.pending(),
      );
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: server,
        now: () => DateTime.utc(2026, 8, 30, 10),
      );
      final PaymentRequest changed = PaymentRequest(
        requestId: original.requestId,
        expiresAt: DateTime.utc(2026, 8, 30, 12),
      );

      final Future<void> failed = expectLater(
        bloc.stream,
        emits(
          predicate<PaymentRequestFailure>(
            (PaymentRequestFailure state) => !state.retryable,
          ),
        ),
      );
      bloc.add(PaymentRequestSubmitted(changed));
      await failed;

      expect(server.calls, 0);
      expect(store.value?.request.expiresAt, original.expiresAt);
      expect(store.value?.status, PaymentRequestStatus.paid);
      await bloc.close();
    },
  );

  test(
    'a known port failure exposes retryable failure without overwriting pending state',
    () async {
      final PaymentRequest request = PaymentRequest(
        requestId: 'request-004',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );
      final _Store store = _Store();
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: _FailingServer(),
        now: () => DateTime.utc(2026, 8, 30, 10),
      );

      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PaymentRequestPending>(),
          isA<PaymentRequestFailure>(),
        ]),
      );
      bloc.add(PaymentRequestSubmitted(request));
      await states;
      expect(store.value?.status, PaymentRequestStatus.pending);
      await bloc.close();
    },
  );

  test(
    'a failed pending request retries to an authoritative paid state',
    () async {
      final PaymentRequest request = PaymentRequest(
        requestId: 'request-005',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );
      final _Store store = _Store();
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: _FailOnceServer(),
        now: () => DateTime.utc(2026, 8, 30, 10),
      );

      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PaymentRequestPending>(),
          isA<PaymentRequestFailure>(),
          isA<PaymentRequestRetrying>(),
          isA<PaymentRequestPaid>(),
        ]),
      );
      bloc.add(PaymentRequestSubmitted(request));
      await Future<void>.delayed(Duration.zero);
      bloc.add(PaymentRequestRetryRequested(request));
      await states;
      expect(store.value?.status, PaymentRequestStatus.paid);
      await bloc.close();
    },
  );

  test('retry recovers when the initial durable pending save fails', () async {
    final PaymentRequest request = PaymentRequest(
      requestId: 'request-006',
      expiresAt: DateTime.utc(2026, 8, 30, 11),
    );
    final _FailFirstSaveStore store = _FailFirstSaveStore();
    final _Server server = _Server(const PaymentRequestServerResult.paid());
    final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
      store: store,
      server: server,
      now: () => DateTime.utc(2026, 8, 30, 10),
    );

    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PaymentRequestFailure>(),
        isA<PaymentRequestRetrying>(),
        isA<PaymentRequestPaid>(),
      ]),
    );
    bloc
      ..add(PaymentRequestSubmitted(request))
      ..add(PaymentRequestRetryRequested(request));
    await states;

    expect(server.calls, 1);
    expect(store.value?.status, PaymentRequestStatus.paid);
    await bloc.close();
  });

  test('an authoritative server expiry is persisted and emitted', () async {
    final _Store store = _Store();
    final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
      store: store,
      server: _Server(const PaymentRequestServerResult.expired()),
      now: () => DateTime.utc(2026, 8, 30, 10),
    );
    final PaymentRequest request = PaymentRequest(
      requestId: 'request-007',
      expiresAt: DateTime.utc(2026, 8, 30, 11),
    );

    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PaymentRequestPending>(),
        isA<PaymentRequestExpired>(),
      ]),
    );
    bloc.add(PaymentRequestSubmitted(request));
    await states;

    expect(store.value?.status, PaymentRequestStatus.expired);
    await bloc.close();
  });

  test(
    'a failed queued request remains retryable after a later request is paid',
    () async {
      final _Store store = _Store();
      final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
        store: store,
        server: _FailsFirstRequestServer(),
        now: () => DateTime.utc(2026, 8, 30, 10),
      );
      final PaymentRequest first = PaymentRequest(
        requestId: 'request-008',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );
      final PaymentRequest second = PaymentRequest(
        requestId: 'request-009',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      );

      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PaymentRequestPending>(),
          isA<PaymentRequestFailure>(),
          isA<PaymentRequestPending>(),
          predicate<PaymentRequestPaid>(
            (PaymentRequestPaid state) =>
                state.retryableRequests.single.requestId == first.requestId,
          ),
        ]),
      );
      bloc
        ..add(PaymentRequestSubmitted(first))
        ..add(PaymentRequestSubmitted(second));
      await states;
      await bloc.close();
    },
  );

  test('request identifiers are validated in release behavior', () {
    expect(
      () => PaymentRequest(
        requestId: 'bad id',
        expiresAt: DateTime.utc(2026, 8, 30, 11),
      ),
      throwsArgumentError,
    );
  });
}

final class _Store implements PaymentRequestLifecycleStore {
  PaymentRequestSnapshot? value;

  @override
  Future<PaymentRequestSnapshot?> load(String requestId) async =>
      value?.request.requestId == requestId ? value : null;

  @override
  Future<void> save(PaymentRequestSnapshot snapshot) async {
    value = snapshot;
  }
}

final class _FailFirstSaveStore implements PaymentRequestLifecycleStore {
  PaymentRequestSnapshot? value;
  int saves = 0;

  @override
  Future<PaymentRequestSnapshot?> load(String requestId) async =>
      value?.request.requestId == requestId ? value : null;

  @override
  Future<void> save(PaymentRequestSnapshot snapshot) async {
    saves++;
    if (saves == 1) {
      throw const PaymentRequestLifecycleException();
    }
    value = snapshot;
  }
}

final class _Server implements PaymentRequestServer {
  _Server(this.result);

  final PaymentRequestServerResult result;
  int calls = 0;

  @override
  Future<PaymentRequestServerResult> submit(PaymentRequest request) async {
    calls++;
    return result;
  }
}

final class _FailingServer implements PaymentRequestServer {
  @override
  Future<PaymentRequestServerResult> submit(PaymentRequest request) =>
      Future<PaymentRequestServerResult>.error(
        const PaymentRequestLifecycleException(),
      );
}

final class _RecordingServer implements PaymentRequestServer {
  final List<String> requestIds = <String>[];

  @override
  Future<PaymentRequestServerResult> submit(PaymentRequest request) async {
    requestIds.add(request.requestId);
    return const PaymentRequestServerResult.paid();
  }
}

final class _FailOnceServer implements PaymentRequestServer {
  int calls = 0;

  @override
  Future<PaymentRequestServerResult> submit(PaymentRequest request) {
    calls++;
    if (calls == 1) {
      return Future<PaymentRequestServerResult>.error(
        const PaymentRequestLifecycleException(),
      );
    }
    return Future<PaymentRequestServerResult>.value(
      const PaymentRequestServerResult.paid(),
    );
  }
}

final class _FailsFirstRequestServer implements PaymentRequestServer {
  bool _first = true;

  @override
  Future<PaymentRequestServerResult> submit(PaymentRequest request) {
    if (_first) {
      _first = false;
      return Future<PaymentRequestServerResult>.error(
        const PaymentRequestLifecycleException(),
      );
    }
    return Future<PaymentRequestServerResult>.value(
      const PaymentRequestServerResult.paid(),
    );
  }
}
