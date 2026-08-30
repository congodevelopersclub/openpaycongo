import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

/// The durable, opaque result of the documented pairing completion protocol.
///
/// This deliberately contains no QR, SAS, bearer, ciphertext, key, tenant, or
/// device identifier. A future authenticated Laravel transport owns those
/// values and exposes only this redacted lifecycle result to the BLoC.
final class PairingEnrollment {
  const PairingEnrollment({required this.phase, required this.updatedAt});

  final PairingEnrollmentPhase phase;
  final DateTime updatedAt;
}

enum PairingEnrollmentPhase { pendingConfirmation, active, recoveryRequired }

/// Secure-storage boundary. Implementations must use platform-backed storage.
abstract interface class PairingEnrollmentStore {
  Future<PairingEnrollment?> load();
  Future<void> save(PairingEnrollment enrollment);
  Future<void> clear();
}

/// Authenticated transport seam for ADR-004's pairing completion/status flow.
///
/// No Laravel HTTP handler or authenticated mobile transport exists yet, so
/// this port intentionally does not manufacture URLs, credentials, or payloads.
abstract interface class PairingEnrollmentTransport {
  Future<PairingEnrollment> begin();
  Future<PairingEnrollment> retry(PairingEnrollment enrollment);
  Future<PairingEnrollment> recover(PairingEnrollment enrollment);

  /// Idempotently destroys locally retained protocol material (including on
  /// user cancellation) before the BLoC confirms durable cleanup.
  Future<void> discardTerminal();
}

/// Expected durable-storage failure; unexpected programming errors propagate.
final class PairingEnrollmentPersistenceException implements Exception {
  const PairingEnrollmentPersistenceException();
}

/// Expected unavailable/timeout transport boundary.
final class PairingEnrollmentUnavailableException implements Exception {
  const PairingEnrollmentUnavailableException();
}

/// Expected terminal protocol result with no sensitive diagnostic payload.
final class PairingEnrollmentProtocolException implements Exception {
  const PairingEnrollmentProtocolException();
}

enum PairingEnrollmentTelemetry {
  started,
  pending,
  active,
  offline,
  error,
  recovered,
  cancelled,
  duplicateIgnored,
}

/// Typed, redacting observability boundary. Signals carry no external data.
abstract interface class PairingEnrollmentTelemetryPort {
  void record(PairingEnrollmentTelemetry signal);
}

sealed class PairingEnrollmentEvent {
  const PairingEnrollmentEvent();
}

final class PairingEnrollmentStarted extends PairingEnrollmentEvent {
  const PairingEnrollmentStarted();
}

final class PairingEnrollmentRetryRequested extends PairingEnrollmentEvent {
  const PairingEnrollmentRetryRequested();
}

final class PairingEnrollmentRecovered extends PairingEnrollmentEvent {
  const PairingEnrollmentRecovered();
}

final class PairingEnrollmentCancelled extends PairingEnrollmentEvent {
  const PairingEnrollmentCancelled();
}

sealed class PairingEnrollmentState {
  const PairingEnrollmentState();
}

final class PairingEnrollmentIdle extends PairingEnrollmentState {
  const PairingEnrollmentIdle();
}

final class PairingEnrollmentLoading extends PairingEnrollmentState {
  const PairingEnrollmentLoading();
}

final class PairingEnrollmentPending extends PairingEnrollmentState {
  const PairingEnrollmentPending(this.enrollment);
  final PairingEnrollment enrollment;
}

final class PairingEnrollmentActive extends PairingEnrollmentState {
  const PairingEnrollmentActive(this.enrollment);
  final PairingEnrollment enrollment;
}

final class PairingEnrollmentRecoveryRequired extends PairingEnrollmentState {
  const PairingEnrollmentRecoveryRequired(this.enrollment);
  final PairingEnrollment enrollment;
}

final class PairingEnrollmentOffline extends PairingEnrollmentState {
  const PairingEnrollmentOffline();
}

final class PairingEnrollmentError extends PairingEnrollmentState {
  const PairingEnrollmentError();
}

final class PairingEnrollmentBloc
    extends Bloc<PairingEnrollmentEvent, PairingEnrollmentState> {
  PairingEnrollmentBloc({
    required this.store,
    required this.transport,
    required this.telemetry,
  }) : super(const PairingEnrollmentIdle()) {
    on<PairingEnrollmentStarted>(_start);
    on<PairingEnrollmentRetryRequested>(_retry);
    on<PairingEnrollmentRecovered>(_recover);
    on<PairingEnrollmentCancelled>(_cancel);
  }

  final PairingEnrollmentStore store;
  final PairingEnrollmentTransport transport;
  final PairingEnrollmentTelemetryPort telemetry;
  int _generation = 0;
  int? _activeOperation;
  Future<void> _persistence = Future<void>.value();
  _CleanupTarget? _pendingCleanup;

  Future<void> _start(
    PairingEnrollmentStarted event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = _generation;
    if (!await _resumeCleanupIfNeeded(generation, emit)) return;
    if (generation != _generation) return;
    await _run(emit, transport.begin, started: true);
  }

  Future<void> _retry(
    PairingEnrollmentRetryRequested event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final int cleanupGeneration = _generation;
    if (!await _resumeCleanupIfNeeded(cleanupGeneration, emit)) return;
    if (cleanupGeneration != _generation) return;
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = _generation;
    final bool wasOffline = state is PairingEnrollmentOffline;
    final PairingEnrollment? enrollment = await _load(emit, generation);
    if (generation != _generation) return;
    if (enrollment == null) {
      if (!wasOffline && state is PairingEnrollmentOffline) return;
      await _run(emit, transport.begin, started: true);
      return;
    }
    await _run(emit, () => transport.retry(enrollment));
  }

  Future<void> _recover(
    PairingEnrollmentRecovered event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final int cleanupGeneration = _generation;
    if (!await _resumeCleanupIfNeeded(cleanupGeneration, emit)) return;
    if (cleanupGeneration != _generation) return;
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = _generation;
    final bool wasOffline = state is PairingEnrollmentOffline;
    final PairingEnrollment? enrollment = await _load(emit, generation);
    if (generation != _generation) return;
    if (enrollment == null) {
      if (!wasOffline && state is PairingEnrollmentOffline) return;
      if (state is! PairingEnrollmentOffline) {
        emit(const PairingEnrollmentIdle());
      }
      return;
    }
    await _run(emit, () => transport.recover(enrollment), recovered: true);
  }

  Future<PairingEnrollment?> _load(
    Emitter<PairingEnrollmentState> emit,
    int generation,
  ) async {
    await _persistence;
    if (generation != _generation) return null;
    try {
      final PairingEnrollment? enrollment = await store.load();
      return generation == _generation ? enrollment : null;
    } on PairingEnrollmentPersistenceException {
      if (generation == _generation) {
        emit(const PairingEnrollmentOffline());
        telemetry.record(PairingEnrollmentTelemetry.offline);
      }
      return null;
    }
  }

  Future<void> _run(
    Emitter<PairingEnrollmentState> emit,
    Future<PairingEnrollment> Function() operation, {
    bool started = false,
    bool recovered = false,
  }) async {
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = ++_generation;
    _activeOperation = generation;
    emit(const PairingEnrollmentLoading());
    if (started) telemetry.record(PairingEnrollmentTelemetry.started);
    try {
      final PairingEnrollment enrollment = await operation();
      if (generation != _generation) return;
      await _save(enrollment);
      if (generation != _generation) return;
      _emitEnrollment(enrollment, emit);
      if (recovered) telemetry.record(PairingEnrollmentTelemetry.recovered);
    } on TimeoutException {
      _offlineIfCurrent(generation, emit);
    } on PairingEnrollmentUnavailableException {
      _offlineIfCurrent(generation, emit);
    } on PairingEnrollmentPersistenceException {
      _offlineIfCurrent(generation, emit);
    } on PairingEnrollmentProtocolException {
      await _discardTerminalIfCurrent(generation, emit);
    } finally {
      if (_activeOperation == generation) _activeOperation = null;
    }
  }

  Future<void> _cancel(
    PairingEnrollmentCancelled event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final int generation = ++_generation;
    _activeOperation = null;
    telemetry.record(PairingEnrollmentTelemetry.cancelled);
    _pendingCleanup = _CleanupTarget.cancelled;
    await _completeCleanup(generation, emit);
  }

  void _offlineIfCurrent(int generation, Emitter<PairingEnrollmentState> emit) {
    if (generation == _generation) {
      emit(const PairingEnrollmentOffline());
      telemetry.record(PairingEnrollmentTelemetry.offline);
    }
  }

  Future<void> _discardTerminalIfCurrent(
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    _pendingCleanup = _CleanupTarget.terminalError;
    await _completeCleanup(generation, emit);
  }

  Future<bool> _resumeCleanupIfNeeded(
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    if (_pendingCleanup == null) return true;
    return _completeCleanup(generation, emit);
  }

  Future<bool> _completeCleanup(
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final _CleanupTarget? target = _pendingCleanup;
    if (target == null) return true;
    try {
      await transport.discardTerminal();
      if (generation != _generation) return false;
      await _clear();
      if (generation != _generation) return false;
      if (_pendingCleanup != target) return false;
      _pendingCleanup = null;
      switch (target) {
        case _CleanupTarget.cancelled:
          emit(const PairingEnrollmentIdle());
        case _CleanupTarget.terminalError:
          emit(const PairingEnrollmentError());
          telemetry.record(PairingEnrollmentTelemetry.error);
      }
      return true;
    } on TimeoutException {
      _offlineIfCurrent(generation, emit);
    } on PairingEnrollmentUnavailableException {
      _offlineIfCurrent(generation, emit);
    } on PairingEnrollmentPersistenceException {
      _offlineIfCurrent(generation, emit);
    }
    return false;
  }

  void _emitEnrollment(
    PairingEnrollment enrollment,
    Emitter<PairingEnrollmentState> emit,
  ) {
    switch (enrollment.phase) {
      case PairingEnrollmentPhase.pendingConfirmation:
        emit(PairingEnrollmentPending(enrollment));
        telemetry.record(PairingEnrollmentTelemetry.pending);
      case PairingEnrollmentPhase.active:
        emit(PairingEnrollmentActive(enrollment));
        telemetry.record(PairingEnrollmentTelemetry.active);
      case PairingEnrollmentPhase.recoveryRequired:
        emit(PairingEnrollmentRecoveryRequired(enrollment));
    }
  }

  Future<void> _save(PairingEnrollment enrollment) =>
      _queue(() => store.save(enrollment));

  Future<void> _clear() => _queue(store.clear);

  Future<void> _queue(Future<void> Function() operation) {
    final Future<void> result = _persistence.then<void>((_) => operation());
    _persistence = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<void> close() {
    _generation++;
    _activeOperation = null;
    return super.close();
  }
}

enum _CleanupTarget { cancelled, terminalError }
