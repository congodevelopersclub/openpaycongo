import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/payment_outbox.dart';
import '../domain/payment_outbox_sync_coordinator.dart';

typedef PaymentLifecycleScope = OutboxScope;

enum PaymentLifecycleOutcome { completed, partial, offline, cancelled }

final class PaymentLifecycleResult {
  const PaymentLifecycleResult({
    required this.outcome,
    this.recovered = 0,
    this.claimed = 0,
    this.acknowledged = 0,
    this.deferred = 0,
  });

  const PaymentLifecycleResult.completed({
    int recovered = 0,
    int claimed = 0,
    int acknowledged = 0,
  }) : this(
         outcome: PaymentLifecycleOutcome.completed,
         recovered: recovered,
         claimed: claimed,
         acknowledged: acknowledged,
       );

  const PaymentLifecycleResult.offline({int recovered = 0, int deferred = 0})
    : this(
        outcome: PaymentLifecycleOutcome.offline,
        recovered: recovered,
        deferred: deferred,
      );

  final PaymentLifecycleOutcome outcome;
  final int recovered;
  final int claimed;
  final int acknowledged;
  final int deferred;
}

abstract interface class PaymentLifecycle {
  Future<PaymentLifecycleResult> sync(PaymentLifecycleScope scope, DateTime now);
}

/// A known operational failure at the lifecycle boundary. Programming errors,
/// invalid state transitions, and contract violations must still surface.
final class PaymentLifecycleException implements Exception {
  const PaymentLifecycleException();
}

/// Keeps the coordinator's injected persistence, credential, and transport
/// dependencies outside the presentation state machine.
final class PaymentOutboxLifecycle implements PaymentLifecycle {
  const PaymentOutboxLifecycle(this._coordinator);

  final PaymentOutboxSyncCoordinator _coordinator;

  @override
  Future<PaymentLifecycleResult> sync(
    PaymentLifecycleScope scope,
    DateTime now,
  ) async {
    final PaymentSyncRun run = await _coordinator.sync(scope, now);
    return PaymentLifecycleResult(
      outcome: switch (run.outcome) {
        PaymentSyncOutcome.completed => PaymentLifecycleOutcome.completed,
        PaymentSyncOutcome.partial => PaymentLifecycleOutcome.partial,
        PaymentSyncOutcome.offline => PaymentLifecycleOutcome.offline,
        PaymentSyncOutcome.cancelled => PaymentLifecycleOutcome.cancelled,
      },
      recovered: run.recovered,
      claimed: run.claimed,
      acknowledged: run.acknowledged,
      deferred: run.deferred,
    );
  }
}

sealed class PaymentLifecycleEvent {
  const PaymentLifecycleEvent(this.scope);

  final PaymentLifecycleScope scope;
}

final class PaymentLifecycleSyncRequested extends PaymentLifecycleEvent {
  const PaymentLifecycleSyncRequested(super.scope);
}

final class PaymentLifecycleRetryRequested extends PaymentLifecycleEvent {
  const PaymentLifecycleRetryRequested(super.scope);
}

sealed class PaymentLifecycleState {
  const PaymentLifecycleState();
}

final class PaymentLifecycleIdle extends PaymentLifecycleState {
  const PaymentLifecycleIdle();
}

final class PaymentLifecycleLoading extends PaymentLifecycleState {
  const PaymentLifecycleLoading(this.scope);

  final PaymentLifecycleScope scope;
}

final class PaymentLifecycleCompleted extends PaymentLifecycleState {
  const PaymentLifecycleCompleted(this.scope, this.result);

  final PaymentLifecycleScope scope;
  final PaymentLifecycleResult result;
}

final class PaymentLifecyclePartial extends PaymentLifecycleState {
  const PaymentLifecyclePartial(this.scope, this.result);

  final PaymentLifecycleScope scope;
  final PaymentLifecycleResult result;
}

final class PaymentLifecycleOffline extends PaymentLifecycleState {
  const PaymentLifecycleOffline(this.scope, this.result);

  final PaymentLifecycleScope scope;
  final PaymentLifecycleResult result;
}

final class PaymentLifecycleCancelled extends PaymentLifecycleState {
  const PaymentLifecycleCancelled(this.scope, this.result);

  final PaymentLifecycleScope scope;
  final PaymentLifecycleResult result;
}

final class PaymentLifecycleFailure extends PaymentLifecycleState {
  const PaymentLifecycleFailure(this.scope);

  final PaymentLifecycleScope scope;
}

final class PaymentLifecycleBloc
    extends Bloc<PaymentLifecycleEvent, PaymentLifecycleState> {
  PaymentLifecycleBloc({required this._lifecycle, DateTime Function()? now})
    :
      _now = now ?? DateTime.now,
      super(const PaymentLifecycleIdle()) {
    on<PaymentLifecycleSyncRequested>(_sync);
    on<PaymentLifecycleRetryRequested>(_sync);
  }

  final PaymentLifecycle _lifecycle;
  final DateTime Function() _now;
  bool _syncInProgress = false;

  Future<void> _sync(
    PaymentLifecycleEvent event,
    Emitter<PaymentLifecycleState> emit,
  ) async {
    if (_syncInProgress) return;
    _syncInProgress = true;
    emit(PaymentLifecycleLoading(event.scope));
    try {
      final PaymentLifecycleResult result = await _lifecycle.sync(
        event.scope,
        _now().toUtc(),
      );
      switch (result.outcome) {
        case PaymentLifecycleOutcome.completed:
          emit(PaymentLifecycleCompleted(event.scope, result));
        case PaymentLifecycleOutcome.partial:
          emit(PaymentLifecyclePartial(event.scope, result));
        case PaymentLifecycleOutcome.offline:
          emit(PaymentLifecycleOffline(event.scope, result));
        case PaymentLifecycleOutcome.cancelled:
          emit(PaymentLifecycleCancelled(event.scope, result));
      }
    } on PaymentLifecycleException {
      emit(PaymentLifecycleFailure(event.scope));
    } finally {
      _syncInProgress = false;
    }
  }
}
