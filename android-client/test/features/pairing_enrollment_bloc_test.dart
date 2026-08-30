import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_enrollment_bloc.dart';

void main() {
  test('persists a pending enrollment and recovers it after restart', () async {
    final _Store store = _Store();
    final _Telemetry telemetry = _Telemetry();
    final PairingEnrollment enrollment = PairingEnrollment(
      phase: PairingEnrollmentPhase.pendingConfirmation,
      updatedAt: DateTime.utc(2026, 8, 30),
    );
    final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
      store: store,
      transport: _Transport(enrollment),
      telemetry: telemetry,
    );
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentPending>(),
      ]),
    );

    bloc.add(const PairingEnrollmentStarted());

    await states;
    expect(store.value, same(enrollment));
    await bloc.close();

    final PairingEnrollmentBloc restarted = PairingEnrollmentBloc(
      store: store,
      transport: _Transport(enrollment),
      telemetry: telemetry,
    );
    final Future<void> restored = expectLater(
      restarted.stream,
      emitsInOrder(<Matcher>[
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentPending>(),
      ]),
    );

    restarted.add(const PairingEnrollmentRecovered());

    await restored;
    expect(telemetry.signals, contains(PairingEnrollmentTelemetry.recovered));
    await restarted.close();
  });

  test(
    'cancel wins over an in-flight enrollment and clears durable state',
    () async {
      final Completer<PairingEnrollment> begin = Completer<PairingEnrollment>();
      final _Store store = _Store();
      final _DeferredTransport transport = _DeferredTransport(begin);
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: store,
        transport: transport,
        telemetry: _Telemetry(),
      );
      bloc.add(const PairingEnrollmentStarted());
      await Future<void>.delayed(Duration.zero);
      final Future<PairingEnrollmentState> idle = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentIdle,
      );
      bloc.add(const PairingEnrollmentCancelled());
      await idle;
      begin.complete(_pending());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<PairingEnrollmentIdle>());
      expect(store.value, isNull);
      expect(transport.discardCalls, 1);
      await bloc.close();
    },
  );

  test('timeout becomes offline and retry reaches active enrollment', () async {
    final _Store store = _Store();
    final _RetryTransport transport = _RetryTransport();
    final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
      store: store,
      transport: transport,
      telemetry: _Telemetry(),
    );
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentOffline>(),
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentActive>(),
      ]),
    );

    bloc.add(const PairingEnrollmentStarted());
    await bloc.stream.firstWhere(
      (PairingEnrollmentState state) => state is PairingEnrollmentOffline,
    );
    bloc.add(const PairingEnrollmentRetryRequested());

    await states;
    expect(transport.beginCalls, 2);
    await bloc.close();
  });

  test(
    'typed protocol failure emits error and recovery without state is empty',
    () async {
      final _ProtocolFailureTransport transport = _ProtocolFailureTransport();
      final _Store store = _Store()..value = _pending();
      final _Telemetry telemetry = _Telemetry();
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: store,
        transport: transport,
        telemetry: telemetry,
      );
      final Future<PairingEnrollmentState> error = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentError,
      );
      bloc.add(const PairingEnrollmentStarted());
      await error;
      bloc.add(const PairingEnrollmentRecovered());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<PairingEnrollmentIdle>());
      expect(store.value, isNull);
      expect(transport.discardCalls, 1);
      expect(telemetry.signals, contains(PairingEnrollmentTelemetry.error));
      await bloc.close();
    },
  );

  test(
    'terminal cleanup failure is retryable offline, not terminal error',
    () async {
      final _ProtocolFailureTransport transport = _ProtocolFailureTransport();
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: const _FailingClearStore(),
        transport: transport,
        telemetry: _Telemetry(),
      );
      final Future<PairingEnrollmentState> offline = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentOffline,
      );

      bloc.add(const PairingEnrollmentStarted());

      await offline;
      expect(bloc.state, isA<PairingEnrollmentOffline>());
      expect(transport.discardCalls, 1);
      await bloc.close();
    },
  );

  test(
    'retry resumes failed terminal disposal before any fresh enrollment',
    () async {
      final _Store store = _Store()..value = _pending();
      final _FlakyDiscardTransport transport = _FlakyDiscardTransport();
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: store,
        transport: transport,
        telemetry: _Telemetry(),
      );
      final Future<PairingEnrollmentState> offline = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentOffline,
      );
      bloc.add(const PairingEnrollmentStarted());
      await offline;
      expect(store.value, isNotNull);

      final Future<PairingEnrollmentState> error = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentError,
      );
      bloc.add(const PairingEnrollmentRetryRequested());
      await error;

      expect(store.value, isNull);
      expect(transport.discardCalls, 2);
      expect(transport.beginCalls, 1);
      await bloc.close();
    },
  );

  test('restart resumes durable cleanup after disposal failure', () async {
    final _Store store = _Store()..value = _pending();
    final _FlakyDiscardTransport transport = _FlakyDiscardTransport();
    final PairingEnrollmentBloc first = PairingEnrollmentBloc(
      store: store,
      transport: transport,
      telemetry: _Telemetry(),
    );
    final Future<PairingEnrollmentState> offline = first.stream.firstWhere(
      (PairingEnrollmentState state) => state is PairingEnrollmentOffline,
    );
    first.add(const PairingEnrollmentCancelled());
    await offline;
    expect(store.cleanup, PairingEnrollmentCleanup.cancelled);
    await first.close();

    final PairingEnrollmentBloc restarted = PairingEnrollmentBloc(
      store: store,
      transport: transport,
      telemetry: _Telemetry(),
    );
    final Future<PairingEnrollmentState> idle = restarted.stream.firstWhere(
      (PairingEnrollmentState state) => state is PairingEnrollmentIdle,
    );
    restarted.add(const PairingEnrollmentRecovered());
    await idle;

    expect(store.value, isNull);
    expect(store.cleanup, isNull);
    await restarted.close();
  });

  test(
    'close during cleanup leaves durable intent for restart reconciliation',
    () async {
      final _Store store = _Store()..value = _pending();
      final _DeferredDiscardTransport transport = _DeferredDiscardTransport();
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: store,
        transport: transport,
        telemetry: _Telemetry(),
      );
      bloc.add(const PairingEnrollmentCancelled());
      await transport.discardEntered.future;
      await bloc.close();
      transport.releaseDiscard.complete();
      await Future<void>.delayed(Duration.zero);

      expect(store.cleanup, PairingEnrollmentCleanup.cancelled);
      expect(store.value, isNotNull);

      final PairingEnrollmentBloc restarted = PairingEnrollmentBloc(
        store: store,
        transport: _CountingTransport(),
        telemetry: _Telemetry(),
      );
      final Future<PairingEnrollmentState> idle = restarted.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentIdle,
      );
      restarted.add(const PairingEnrollmentRecovered());
      await idle;
      expect(store.value, isNull);
      expect(store.cleanup, isNull);
      await restarted.close();
    },
  );

  test('close invalidates a late begin before it can persist', () async {
    final Completer<PairingEnrollment> begin = Completer<PairingEnrollment>();
    final _Store store = _Store();
    final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
      store: store,
      transport: _DeferredTransport(begin),
      telemetry: _Telemetry(),
    );
    bloc.add(const PairingEnrollmentStarted());
    await Future<void>.delayed(Duration.zero);
    await bloc.close();
    begin.complete(_pending());
    await Future<void>.delayed(Duration.zero);

    expect(store.value, isNull);
  });

  test(
    'stale protocol failure cannot replace cancellation cleanup intent',
    () async {
      final Completer<PairingEnrollment> begin = Completer<PairingEnrollment>();
      final _Store store = _Store();
      final _DeferredTransport transport = _DeferredTransport(begin);
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: store,
        transport: transport,
        telemetry: _Telemetry(),
      );
      bloc.add(const PairingEnrollmentStarted());
      await Future<void>.delayed(Duration.zero);
      final Future<PairingEnrollmentState> idle = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentIdle,
      );
      bloc.add(const PairingEnrollmentCancelled());
      await idle;
      begin.completeError(const PairingEnrollmentProtocolException());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<PairingEnrollmentIdle>());
      expect(transport.discardCalls, 1);
      expect(store.value, isNull);
      await bloc.close();
    },
  );

  for (final PairingEnrollmentEvent event in <PairingEnrollmentEvent>[
    const PairingEnrollmentRetryRequested(),
    const PairingEnrollmentRecovered(),
  ]) {
    test(
      'cancel during deferred $event cannot revive loaded enrollment',
      () async {
        final _DeferredLoadStore store = _DeferredLoadStore();
        final _CountingTransport transport = _CountingTransport();
        final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
          store: store,
          transport: transport,
          telemetry: _Telemetry(),
        );

        bloc.add(event);
        await store.loadEntered.future;
        final Future<PairingEnrollmentState> idle = bloc.stream.firstWhere(
          (PairingEnrollmentState state) => state is PairingEnrollmentIdle,
        );
        bloc.add(const PairingEnrollmentCancelled());
        await idle;
        store.releaseLoad.complete(_pending());
        await Future<void>.delayed(Duration.zero);

        expect(bloc.state, isA<PairingEnrollmentIdle>());
        expect(store.value, isNull);
        expect(transport.calls, 0);
        await bloc.close();
      },
    );
  }

  for (final PairingEnrollmentEvent event in <PairingEnrollmentEvent>[
    const PairingEnrollmentRetryRequested(),
    const PairingEnrollmentRecovered(),
  ]) {
    test('unexpected load error reaches the observer for $event', () async {
      final _RecordingObserver observer = _RecordingObserver();
      final BlocObserver previous = Bloc.observer;
      Bloc.observer = observer;
      addTearDown(() => Bloc.observer = previous);
      final Completer<Object> uncaught = Completer<Object>();
      late final PairingEnrollmentBloc bloc;
      runZonedGuarded(() {
        bloc = PairingEnrollmentBloc(
          store: const _UnexpectedLoadStore(),
          transport: _Transport(_pending()),
          telemetry: _Telemetry(),
        );
        bloc.add(event);
      }, (Object error, StackTrace _) => uncaught.complete(error));

      await observer.error;
      expect(observer.observed, isA<StateError>());
      expect(await uncaught.future, isA<StateError>());
      await bloc.close();
    });
  }
}

PairingEnrollment _pending() => PairingEnrollment(
  phase: PairingEnrollmentPhase.pendingConfirmation,
  updatedAt: DateTime.utc(2026, 8, 30),
);

final class _Store implements PairingEnrollmentStore {
  PairingEnrollment? value;
  PairingEnrollmentCleanup? cleanup;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<PairingEnrollment?> load() async => value;

  @override
  Future<void> save(PairingEnrollment enrollment) async => value = enrollment;

  @override
  Future<PairingEnrollmentCleanup?> loadCleanup() async => cleanup;

  @override
  Future<void> saveCleanup(PairingEnrollmentCleanup cleanup) async =>
      this.cleanup = cleanup;

  @override
  Future<void> clearCleanup() async => cleanup = null;
}

final class _Transport implements PairingEnrollmentTransport {
  const _Transport(this.enrollment);

  final PairingEnrollment enrollment;

  @override
  Future<PairingEnrollment> begin() async => enrollment;

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      this.enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      this.enrollment;

  @override
  Future<void> discardTerminal() async {}
}

final class _Telemetry implements PairingEnrollmentTelemetryPort {
  final List<PairingEnrollmentTelemetry> signals =
      <PairingEnrollmentTelemetry>[];

  @override
  void record(PairingEnrollmentTelemetry signal) => signals.add(signal);
}

final class _DeferredTransport implements PairingEnrollmentTransport {
  _DeferredTransport(this.beginResult);

  final Completer<PairingEnrollment> beginResult;
  int discardCalls = 0;

  @override
  Future<PairingEnrollment> begin() => beginResult.future;

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<void> discardTerminal() async => discardCalls++;
}

final class _RetryTransport implements PairingEnrollmentTransport {
  int beginCalls = 0;

  @override
  Future<PairingEnrollment> begin() async {
    beginCalls++;
    if (beginCalls == 1) throw TimeoutException('unavailable');
    return PairingEnrollment(
      phase: PairingEnrollmentPhase.active,
      updatedAt: DateTime.utc(2026, 8, 30),
    );
  }

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<void> discardTerminal() async {}
}

final class _ProtocolFailureTransport implements PairingEnrollmentTransport {
  int discardCalls = 0;

  @override
  Future<PairingEnrollment> begin() async =>
      throw const PairingEnrollmentProtocolException();

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<void> discardTerminal() async => discardCalls++;
}

final class _DeferredLoadStore implements PairingEnrollmentStore {
  final Completer<void> loadEntered = Completer<void>();
  final Completer<PairingEnrollment?> releaseLoad =
      Completer<PairingEnrollment?>();
  PairingEnrollment? value;
  PairingEnrollmentCleanup? cleanup;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<PairingEnrollment?> load() {
    if (!loadEntered.isCompleted) loadEntered.complete();
    return releaseLoad.future;
  }

  @override
  Future<void> save(PairingEnrollment enrollment) async => value = enrollment;

  @override
  Future<PairingEnrollmentCleanup?> loadCleanup() async => cleanup;

  @override
  Future<void> saveCleanup(PairingEnrollmentCleanup cleanup) async =>
      this.cleanup = cleanup;

  @override
  Future<void> clearCleanup() async => cleanup = null;
}

final class _FailingClearStore implements PairingEnrollmentStore {
  const _FailingClearStore();

  @override
  Future<void> clear() async =>
      throw const PairingEnrollmentPersistenceException();

  @override
  Future<PairingEnrollment?> load() async => null;

  @override
  Future<void> save(PairingEnrollment enrollment) async {}

  @override
  Future<PairingEnrollmentCleanup?> loadCleanup() async => null;

  @override
  Future<void> saveCleanup(PairingEnrollmentCleanup cleanup) async {}

  @override
  Future<void> clearCleanup() async {}
}

final class _FlakyDiscardTransport implements PairingEnrollmentTransport {
  int beginCalls = 0;
  int discardCalls = 0;

  @override
  Future<PairingEnrollment> begin() async {
    beginCalls++;
    throw const PairingEnrollmentProtocolException();
  }

  @override
  Future<void> discardTerminal() async {
    discardCalls++;
    if (discardCalls == 1) throw const PairingEnrollmentUnavailableException();
  }

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;
}

final class _DeferredDiscardTransport implements PairingEnrollmentTransport {
  final Completer<void> discardEntered = Completer<void>();
  final Completer<void> releaseDiscard = Completer<void>();

  @override
  Future<PairingEnrollment> begin() async => _pending();

  @override
  Future<void> discardTerminal() {
    if (!discardEntered.isCompleted) discardEntered.complete();
    return releaseDiscard.future;
  }

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;
}

final class _CountingTransport implements PairingEnrollmentTransport {
  int calls = 0;

  @override
  Future<PairingEnrollment> begin() async {
    calls++;
    return _pending();
  }

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async {
    calls++;
    return enrollment;
  }

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async {
    calls++;
    return enrollment;
  }

  @override
  Future<void> discardTerminal() async {}
}

final class _UnexpectedLoadStore implements PairingEnrollmentStore {
  const _UnexpectedLoadStore();

  @override
  Future<void> clear() async {}

  @override
  Future<PairingEnrollment?> load() async => throw StateError('unexpected');

  @override
  Future<void> save(PairingEnrollment enrollment) async {}

  @override
  Future<PairingEnrollmentCleanup?> loadCleanup() async => null;

  @override
  Future<void> saveCleanup(PairingEnrollmentCleanup cleanup) async {}

  @override
  Future<void> clearCleanup() async {}
}

final class _RecordingObserver extends BlocObserver {
  final Completer<void> _error = Completer<void>();
  Object? observed;

  Future<void> get error => _error.future;

  @override
  void onError(BlocBase<Object?> bloc, Object error, StackTrace stackTrace) {
    observed = error;
    if (!_error.isCompleted) _error.complete();
    super.onError(bloc, error, stackTrace);
  }
}
