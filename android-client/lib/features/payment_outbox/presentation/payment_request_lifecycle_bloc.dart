import 'package:flutter_bloc/flutter_bloc.dart';

/// Opaque request identity and expiry supplied by the authenticated payment
/// request boundary. It deliberately carries no payment evidence or secrets.
final class PaymentRequest {
  PaymentRequest({required this.requestId, required DateTime expiresAt})
    : expiresAt = expiresAt.toUtc() {
    if (!RegExp(r'^[A-Za-z0-9_-]{3,64}$').hasMatch(requestId)) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'must be an opaque 3-64 character identifier',
      );
    }
  }

  final String requestId;
  final DateTime expiresAt;
}

enum PaymentRequestStatus { pending, paid, expired }

final class PaymentRequestSnapshot {
  const PaymentRequestSnapshot({required this.request, required this.status});

  final PaymentRequest request;
  final PaymentRequestStatus status;
}

/// Durable local lifecycle boundary. Implementations retain encrypted request
/// material behind this port; the presentation state machine never receives it.
abstract interface class PaymentRequestLifecycleStore {
  Future<PaymentRequestSnapshot?> load(String requestId);
  Future<void> save(PaymentRequestSnapshot snapshot);
}

enum PaymentRequestServerStatus { pending, paid, expired }

/// Server response deliberately exposes only an authoritative lifecycle state.
final class PaymentRequestServerResult {
  const PaymentRequestServerResult.paid()
    : status = PaymentRequestServerStatus.paid;

  const PaymentRequestServerResult.pending()
    : status = PaymentRequestServerStatus.pending;

  const PaymentRequestServerResult.expired()
    : status = PaymentRequestServerStatus.expired;

  final PaymentRequestServerStatus status;
}

/// Authenticated server boundary. Credentials, idempotency bytes, transport,
/// and response parsing stay in its infrastructure adapter.
abstract interface class PaymentRequestServer {
  Future<PaymentRequestServerResult> submit(PaymentRequest request);
}

/// Expected port failures map to the user-recoverable failure state. Other
/// errors surface to the Bloc observer rather than being misrepresented.
final class PaymentRequestLifecycleException implements Exception {
  const PaymentRequestLifecycleException();
}

sealed class PaymentRequestLifecycleEvent {
  const PaymentRequestLifecycleEvent();
}

final class PaymentRequestSubmitted extends PaymentRequestLifecycleEvent {
  const PaymentRequestSubmitted(this.request);

  final PaymentRequest request;
}

final class PaymentRequestRetryRequested extends PaymentRequestLifecycleEvent {
  const PaymentRequestRetryRequested(this.request);

  final PaymentRequest request;
}

sealed class PaymentRequestLifecycleState {
  const PaymentRequestLifecycleState({
    this.retryableRequests = const <PaymentRequest>[],
  });

  /// Pending requests that hit an expected port failure. They remain visible
  /// while later queued events complete, so their retry action is never lost.
  final List<PaymentRequest> retryableRequests;
}

final class PaymentRequestIdle extends PaymentRequestLifecycleState {
  const PaymentRequestIdle({super.retryableRequests});
}

final class PaymentRequestPending extends PaymentRequestLifecycleState {
  const PaymentRequestPending(this.request, {super.retryableRequests});

  final PaymentRequest request;
}

final class PaymentRequestPaid extends PaymentRequestLifecycleState {
  const PaymentRequestPaid(this.request, {super.retryableRequests});

  final PaymentRequest request;
}

final class PaymentRequestExpired extends PaymentRequestLifecycleState {
  const PaymentRequestExpired(this.request, {super.retryableRequests});

  final PaymentRequest request;
}

final class PaymentRequestRetrying extends PaymentRequestLifecycleState {
  const PaymentRequestRetrying(this.request, {super.retryableRequests});

  final PaymentRequest request;
}

final class PaymentRequestFailure extends PaymentRequestLifecycleState {
  const PaymentRequestFailure(
    this.request, {
    this.retryable = true,
    super.retryableRequests,
  });

  final PaymentRequest request;
  final bool retryable;
}

final class PaymentRequestLifecycleBloc
    extends Bloc<PaymentRequestLifecycleEvent, PaymentRequestLifecycleState> {
  PaymentRequestLifecycleBloc({
    required PaymentRequestLifecycleStore store,
    required PaymentRequestServer server,
    DateTime Function()? now,
  }) : this._(store, server, now ?? DateTime.now);

  PaymentRequestLifecycleBloc._(this._store, this._server, this._now)
    : super(const PaymentRequestIdle()) {
    on<PaymentRequestLifecycleEvent>(
      _handle,
      transformer: (events, mapper) => events.asyncExpand(mapper),
    );
  }

  final PaymentRequestLifecycleStore _store;
  final PaymentRequestServer _server;
  final DateTime Function() _now;
  final Map<String, PaymentRequest> _retryableRequests =
      <String, PaymentRequest>{};
  Future<void> _handle(
    PaymentRequestLifecycleEvent event,
    Emitter<PaymentRequestLifecycleState> emit,
  ) => switch (event) {
    PaymentRequestSubmitted() => _submit(event, emit),
    PaymentRequestRetryRequested() => _retry(event, emit),
  };

  Future<void> _submit(
    PaymentRequestSubmitted event,
    Emitter<PaymentRequestLifecycleState> emit,
  ) async {
    try {
      final PaymentRequestSnapshot? existing = await _store.load(
        event.request.requestId,
      );
      if (existing != null) {
        if (!_sameRequest(existing.request, event.request)) {
          _conflict(event.request, emit);
          return;
        }
        _complete(existing.request);
        switch (existing.status) {
          case PaymentRequestStatus.paid:
            emit(
              PaymentRequestPaid(
                existing.request,
                retryableRequests: _retryable(),
              ),
            );
            return;
          case PaymentRequestStatus.expired:
            emit(
              PaymentRequestExpired(
                existing.request,
                retryableRequests: _retryable(),
              ),
            );
            return;
          case PaymentRequestStatus.pending:
            if (_isExpired(existing.request)) {
              await _persist(existing.request, PaymentRequestStatus.expired);
              emit(
                PaymentRequestExpired(
                  existing.request,
                  retryableRequests: _retryable(),
                ),
              );
              return;
            }
            emit(
              PaymentRequestPending(
                existing.request,
                retryableRequests: _retryable(),
              ),
            );
            await _submitPending(existing.request, emit);
            return;
        }
      }
      _complete(event.request);
      if (_isExpired(event.request)) {
        await _persist(event.request, PaymentRequestStatus.expired);
        emit(
          PaymentRequestExpired(event.request, retryableRequests: _retryable()),
        );
        return;
      }
      await _persist(event.request, PaymentRequestStatus.pending);
      emit(
        PaymentRequestPending(event.request, retryableRequests: _retryable()),
      );
      await _submitPending(event.request, emit);
    } on PaymentRequestLifecycleException {
      _fail(event.request, emit);
    }
  }

  Future<void> _retry(
    PaymentRequestRetryRequested event,
    Emitter<PaymentRequestLifecycleState> emit,
  ) async {
    try {
      final PaymentRequestSnapshot? snapshot = await _store.load(
        event.request.requestId,
      );
      if (snapshot != null && !_sameRequest(snapshot.request, event.request)) {
        _conflict(event.request, emit);
        return;
      }
      final PaymentRequest request = snapshot?.request ?? event.request;
      if (snapshot?.status == PaymentRequestStatus.paid) {
        _complete(request);
        emit(PaymentRequestPaid(request, retryableRequests: _retryable()));
        return;
      }
      if (snapshot?.status == PaymentRequestStatus.expired) {
        _complete(request);
        emit(PaymentRequestExpired(request, retryableRequests: _retryable()));
        return;
      }
      if (_isExpired(request)) {
        await _persist(request, PaymentRequestStatus.expired);
        _complete(request);
        emit(PaymentRequestExpired(request, retryableRequests: _retryable()));
        return;
      }
      _complete(request);
      if (snapshot == null) {
        await _persist(request, PaymentRequestStatus.pending);
      }
      emit(PaymentRequestRetrying(request, retryableRequests: _retryable()));
      await _submitPending(request, emit);
    } on PaymentRequestLifecycleException {
      _fail(event.request, emit);
    }
  }

  Future<void> _submitPending(
    PaymentRequest request,
    Emitter<PaymentRequestLifecycleState> emit,
  ) async {
    final PaymentRequestServerResult result = await _server.submit(request);
    final PaymentRequestStatus status = switch (result.status) {
      PaymentRequestServerStatus.pending => PaymentRequestStatus.pending,
      PaymentRequestServerStatus.paid => PaymentRequestStatus.paid,
      PaymentRequestServerStatus.expired => PaymentRequestStatus.expired,
    };
    await _persist(request, status);
    _complete(request);
    switch (status) {
      case PaymentRequestStatus.pending:
        emit(PaymentRequestPending(request, retryableRequests: _retryable()));
      case PaymentRequestStatus.paid:
        emit(PaymentRequestPaid(request, retryableRequests: _retryable()));
      case PaymentRequestStatus.expired:
        emit(PaymentRequestExpired(request, retryableRequests: _retryable()));
    }
  }

  Future<void> _persist(PaymentRequest request, PaymentRequestStatus status) =>
      _store.save(PaymentRequestSnapshot(request: request, status: status));

  void _fail(
    PaymentRequest request,
    Emitter<PaymentRequestLifecycleState> emit,
  ) {
    _retryableRequests[request.requestId] = request;
    emit(PaymentRequestFailure(request, retryableRequests: _retryable()));
  }

  void _conflict(
    PaymentRequest request,
    Emitter<PaymentRequestLifecycleState> emit,
  ) {
    emit(
      PaymentRequestFailure(
        request,
        retryable: false,
        retryableRequests: _retryable(),
      ),
    );
  }

  void _complete(PaymentRequest request) =>
      _retryableRequests.remove(request.requestId);

  List<PaymentRequest> _retryable() =>
      List<PaymentRequest>.unmodifiable(_retryableRequests.values);

  bool _sameRequest(PaymentRequest first, PaymentRequest second) =>
      first.requestId == second.requestId &&
      first.expiresAt == second.expiresAt;

  bool _isExpired(PaymentRequest request) =>
      !request.expiresAt.isAfter(_now().toUtc());
}
