import 'package:flutter_bloc/flutter_bloc.dart';

final class SyncCursor {
  const SyncCursor(this.value);
  final String value;
}

abstract interface class SyncCursorStore {
  Future<SyncCursor?> load();
  Future<void> save(SyncCursor cursor);
  Future<void> clear();
}

/// A server contract seam. The application supplies the actual transport later.
abstract interface class SyncCursorContract {
  Future<SyncCursorReconciliation> reconcile(SyncCursor? durableCursor);
  Future<SyncCursorDeliveryDecision> classifyDelivery(
    SyncCursor? durableCursor,
    SyncCursor delivery,
  );
}

enum SyncCursorDeliveryDecision { accept, duplicate, stale }

enum SyncCursorHealth { current, stale, degraded }

final class SyncCursorReconciliation {
  const SyncCursorReconciliation({required this.cursor, required this.health});

  final SyncCursor? cursor;
  final SyncCursorHealth health;
}

abstract interface class SyncCursorTelemetry {
  void record(SyncCursorTelemetrySignal signal);
}

enum SyncCursorTelemetrySignal {
  retryRequested,
  offline,
  recovered,
  staleCursor,
  degraded,
  duplicateIgnored,
}

/// Expected durable or transport failure. Programming errors propagate.
final class SyncCursorFailure implements Exception {
  const SyncCursorFailure();
}

sealed class SyncCursorEvent {
  const SyncCursorEvent();
}

final class SyncCursorStarted extends SyncCursorEvent {
  const SyncCursorStarted();
}

final class SyncCursorRetryRequested extends SyncCursorEvent {
  const SyncCursorRetryRequested();
}

final class SyncCursorRecovered extends SyncCursorEvent {
  const SyncCursorRecovered();
}

/// A delivery acknowledgement carries only its opaque cursor checkpoint.
final class SyncCursorDeliveryReceived extends SyncCursorEvent {
  const SyncCursorDeliveryReceived(this.cursor);

  final SyncCursor cursor;
}

sealed class SyncCursorState {
  const SyncCursorState();
}

final class SyncCursorLoading extends SyncCursorState {
  const SyncCursorLoading();
}

final class SyncCursorEmpty extends SyncCursorState {
  const SyncCursorEmpty();
}

final class SyncCursorSynced extends SyncCursorState {
  const SyncCursorSynced(this.cursor);

  final SyncCursor cursor;
}

final class SyncCursorStale extends SyncCursorState {
  const SyncCursorStale(this.cursor);

  final SyncCursor cursor;
}

final class SyncCursorDegraded extends SyncCursorState {
  const SyncCursorDegraded(this.cursor);

  final SyncCursor? cursor;
}

final class SyncCursorOffline extends SyncCursorState {
  const SyncCursorOffline();
}

/// Owns sync state only; it does not carry records, identities, or SMS content.
final class SyncCursorBloc extends Bloc<SyncCursorEvent, SyncCursorState> {
  SyncCursorBloc({
    required this.store,
    required this.contract,
    required this.telemetry,
  }) : super(const SyncCursorEmpty()) {
    on<SyncCursorStarted>(_sync);
    on<SyncCursorRetryRequested>(_retry);
    on<SyncCursorRecovered>(_sync);
    on<SyncCursorDeliveryReceived>(_delivery);
  }
  final SyncCursorStore store;
  final SyncCursorContract contract;
  final SyncCursorTelemetry telemetry;
  int _generation = 0;
  Future<void> _persistence = Future<void>.value();

  Future<void> _save(SyncCursor cursor) {
    final Future<void> attempt = _persistence.then((_) => store.save(cursor));
    _persistence = attempt.catchError((Object _) {});
    return attempt;
  }

  Future<void> _clear() {
    final Future<void> attempt = _persistence.then((_) => store.clear());
    _persistence = attempt.catchError((Object _) {});
    return attempt;
  }

  Future<SyncCursor?> _load() async {
    await _persistence;
    return store.load();
  }

  Future<void> _retry(
    SyncCursorRetryRequested event,
    Emitter<SyncCursorState> emit,
  ) async {
    telemetry.record(SyncCursorTelemetrySignal.retryRequested);
    await _sync(event, emit);
  }

  Future<void> _sync(
    SyncCursorEvent event,
    Emitter<SyncCursorState> emit,
  ) async {
    final int generation = ++_generation;
    emit(const SyncCursorLoading());
    try {
      final SyncCursor? current = await _load();
      if (generation != _generation) return;
      final SyncCursorReconciliation reconciliation = await contract.reconcile(
        current,
      );
      if (generation != _generation) return;
      final SyncCursor? next = reconciliation.cursor;
      if (next == null) {
        await _clear();
        if (generation != _generation) return;
        if (reconciliation.health == SyncCursorHealth.degraded) {
          emit(const SyncCursorDegraded(null));
          telemetry.record(SyncCursorTelemetrySignal.degraded);
        } else {
          emit(const SyncCursorEmpty());
        }
        return;
      }
      if (current?.value != next.value) {
        await _save(next);
        if (generation != _generation) return;
      }
      switch (reconciliation.health) {
        case SyncCursorHealth.current:
          emit(SyncCursorSynced(next));
          if (event is SyncCursorRetryRequested ||
              event is SyncCursorRecovered) {
            telemetry.record(SyncCursorTelemetrySignal.recovered);
          }
        case SyncCursorHealth.stale:
          emit(SyncCursorStale(next));
          telemetry.record(SyncCursorTelemetrySignal.staleCursor);
        case SyncCursorHealth.degraded:
          emit(SyncCursorDegraded(next));
          telemetry.record(SyncCursorTelemetrySignal.degraded);
      }
    } on SyncCursorFailure {
      if (generation == _generation) {
        emit(const SyncCursorOffline());
        telemetry.record(SyncCursorTelemetrySignal.offline);
      }
    }
  }

  Future<void> _delivery(
    SyncCursorDeliveryReceived event,
    Emitter<SyncCursorState> emit,
  ) async {
    final int generation = ++_generation;
    try {
      final SyncCursor? current = await _load();
      if (generation != _generation) return;
      final SyncCursorDeliveryDecision decision = await contract
          .classifyDelivery(current, event.cursor);
      if (generation != _generation) return;
      if (decision == SyncCursorDeliveryDecision.duplicate) {
        telemetry.record(SyncCursorTelemetrySignal.duplicateIgnored);
        emit(SyncCursorSynced(event.cursor));
        return;
      }
      if (decision == SyncCursorDeliveryDecision.stale) {
        telemetry.record(SyncCursorTelemetrySignal.staleCursor);
        emit(
          current == null ? const SyncCursorEmpty() : SyncCursorSynced(current),
        );
        return;
      }
      await _save(event.cursor);
      if (generation != _generation) return;
      emit(SyncCursorSynced(event.cursor));
    } on SyncCursorFailure {
      if (generation == _generation) {
        emit(const SyncCursorOffline());
        telemetry.record(SyncCursorTelemetrySignal.offline);
      }
    }
  }
}
