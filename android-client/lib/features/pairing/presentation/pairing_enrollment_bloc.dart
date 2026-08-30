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
  Future<PairingEnrollmentCleanup?> loadCleanup();
  Future<void> saveCleanup(PairingEnrollmentCleanup cleanup);
  Future<void> clearCleanup();
}

/// Redacted durable cleanup authority; it contains no pairing material.
enum PairingEnrollmentCleanup { cancelled, terminalError }

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
  Future<void>? _activeWork;
  Future<void>? _cleanupTransition;
  Future<void> _persistence = Future<void>.value();
  Future<void> _cleanup = Future<void>.value();
  PairingEnrollmentCleanup? _pendingCleanup;
  PairingEnrollmentCleanup? _unsavedCleanup;

  Future<void> _start(
    PairingEnrollmentStarted event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = _generation;
    final _CleanupResume cleanup = await _restoreAndResumeCleanup(
      generation,
      emit,
    );
    if (cleanup == _CleanupResume.failed) return;
    if (generation != _generation) return;
    await _run(emit, transport.begin, started: true);
  }

  Future<void> _retry(
    PairingEnrollmentRetryRequested event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final int cleanupGeneration = _generation;
    final _CleanupResume cleanup = await _restoreAndResumeCleanup(
      cleanupGeneration,
      emit,
    );
    if (cleanup == _CleanupResume.failed) return;
    if (cleanupGeneration != _generation) return;
    if (cleanup == _CleanupResume.resumed) return;
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = _generation;
    final bool wasOffline = state is PairingEnrollmentOffline;
    final _EnrollmentLoad load = await _load(emit, generation);
    if (generation != _generation) return;
    if (load.failed) return;
    final PairingEnrollment? enrollment = load.enrollment;
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
    final _CleanupResume cleanup = await _restoreAndResumeCleanup(
      cleanupGeneration,
      emit,
    );
    if (cleanup == _CleanupResume.failed) return;
    if (cleanupGeneration != _generation) return;
    if (cleanup == _CleanupResume.resumed) return;
    if (_activeOperation != null) {
      telemetry.record(PairingEnrollmentTelemetry.duplicateIgnored);
      return;
    }
    final int generation = _generation;
    final bool wasOffline = state is PairingEnrollmentOffline;
    final _EnrollmentLoad load = await _load(emit, generation);
    if (generation != _generation) return;
    if (load.failed) return;
    final PairingEnrollment? enrollment = load.enrollment;
    if (enrollment == null) {
      if (!wasOffline && state is PairingEnrollmentOffline) return;
      if (state is! PairingEnrollmentOffline) {
        emit(const PairingEnrollmentIdle());
      }
      return;
    }
    await _run(emit, () => transport.recover(enrollment), recovered: true);
  }

  Future<_EnrollmentLoad> _load(
    Emitter<PairingEnrollmentState> emit,
    int generation,
  ) async {
    await _persistence;
    if (generation != _generation) return const _EnrollmentLoad.stale();
    try {
      final PairingEnrollment? enrollment = await store.load();
      return generation == _generation
          ? _EnrollmentLoad.value(enrollment)
          : const _EnrollmentLoad.stale();
    } on PairingEnrollmentPersistenceException {
      if (generation == _generation) {
        emit(const PairingEnrollmentOffline());
        telemetry.record(PairingEnrollmentTelemetry.offline);
      }
      return const _EnrollmentLoad.failed();
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
    final Completer<void> settled = Completer<void>();
    _activeWork = settled.future;
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
      if (!settled.isCompleted) settled.complete();
      if (_activeWork == settled.future) _activeWork = null;
      if (_activeOperation == generation) _activeOperation = null;
    }
  }

  Future<void> _cancel(
    PairingEnrollmentCancelled event,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final int generation = ++_generation;
    final Future<void>? activeWork = _activeWork;
    final Completer<void> settled = Completer<void>();
    _cleanupTransition = settled.future;
    telemetry.record(PairingEnrollmentTelemetry.cancelled);
    _activeOperation = generation;
    try {
      if (activeWork != null) await activeWork;
      if (generation != _generation) return;
      if (!await _installCleanup(
        PairingEnrollmentCleanup.cancelled,
        generation,
        emit,
      )) {
        return;
      }
      await _completeCleanup(generation, emit);
    } finally {
      if (!settled.isCompleted) settled.complete();
      if (_cleanupTransition == settled.future) _cleanupTransition = null;
      if (_activeOperation == generation) _activeOperation = null;
    }
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
    if (generation != _generation) return;
    if (!await _installCleanup(
      PairingEnrollmentCleanup.terminalError,
      generation,
      emit,
    )) {
      return;
    }
    await _completeCleanup(generation, emit);
  }

  Future<_CleanupResume> _restoreAndResumeCleanup(
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final PairingEnrollmentCleanup? unsaved = _unsavedCleanup;
    if (unsaved != null) {
      if (!await _installCleanup(unsaved, generation, emit)) {
        return _CleanupResume.failed;
      }
      return await _completeCleanup(generation, emit)
          ? _CleanupResume.resumed
          : _CleanupResume.failed;
    }
    if (_pendingCleanup == null) {
      await _persistence;
      if (generation != _generation) return _CleanupResume.failed;
      try {
        final PairingEnrollmentCleanup? cleanup = await store.loadCleanup();
        if (generation != _generation) return _CleanupResume.failed;
        _pendingCleanup = cleanup;
      } on PairingEnrollmentPersistenceException {
        _offlineIfCurrent(generation, emit);
        return _CleanupResume.failed;
      }
    }
    if (_pendingCleanup == null) return _CleanupResume.none;
    return await _completeCleanup(generation, emit)
        ? _CleanupResume.resumed
        : _CleanupResume.failed;
  }

  Future<bool> _installCleanup(
    PairingEnrollmentCleanup target,
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    try {
      await _queue(() => store.saveCleanup(target));
      if (generation != _generation) return false;
      _pendingCleanup = target;
      _unsavedCleanup = null;
      return true;
    } on PairingEnrollmentPersistenceException {
      if (generation != _generation) return false;
      _unsavedCleanup = target;
      await _failClosedFallback(generation);
      _offlineIfCurrent(generation, emit);
      return false;
    }
  }

  Future<bool> _failClosedFallback(int generation) async {
    if (generation != _generation) return false;
    var disposed = false;
    try {
      await transport.discardTerminal();
      disposed = true;
    } on TimeoutException {
      // Removing durable state still prevents restart recovery.
    } on PairingEnrollmentUnavailableException {
      // Removing durable state still prevents restart recovery.
    } on PairingEnrollmentPersistenceException {
      // Removing durable state still prevents restart recovery.
    }
    if (generation != _generation) return false;
    try {
      await _clear();
    } on PairingEnrollmentPersistenceException {
      return false;
    }
    return disposed && generation == _generation;
  }

  Future<bool> _completeCleanup(
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    final PairingEnrollmentCleanup? target = _pendingCleanup;
    if (target == null) return true;
    final Future<bool> result = _cleanup.then<bool>(
      (_) => _performCleanup(target, generation, emit),
    );
    _cleanup = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> _performCleanup(
    PairingEnrollmentCleanup target,
    int generation,
    Emitter<PairingEnrollmentState> emit,
  ) async {
    try {
      if (generation != _generation || _pendingCleanup != target) {
        return false;
      }
      await transport.discardTerminal();
      if (generation != _generation) return false;
      await _clear();
      if (generation != _generation) return false;
      if (_pendingCleanup != target) return false;
      await _queue(store.clearCleanup);
      if (generation != _generation) return false;
      _pendingCleanup = null;
      _unsavedCleanup = null;
      switch (target) {
        case PairingEnrollmentCleanup.cancelled:
          emit(const PairingEnrollmentIdle());
        case PairingEnrollmentCleanup.terminalError:
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
  Future<void> close() async {
    final Future<void>? cleanupTransition = _cleanupTransition;
    if (cleanupTransition != null) await cleanupTransition;
    final int generation = ++_generation;
    final Future<void>? activeWork = _activeWork;
    try {
      if (activeWork != null) {
        var cleanupMarkerSaved = false;
        try {
          await _queue(
            () => store.saveCleanup(PairingEnrollmentCleanup.cancelled),
          );
          cleanupMarkerSaved = true;
        } on PairingEnrollmentPersistenceException {
          _unsavedCleanup = PairingEnrollmentCleanup.cancelled;
        }
        await activeWork;
        if (generation != _generation) return;
        if (!cleanupMarkerSaved) {
          await _failClosedFallback(generation);
          return;
        }
        try {
          await transport.discardTerminal();
          if (generation != _generation) {
            return;
          }
          await _clear();
          if (generation != _generation) {
            return;
          }
          await _queue(store.clearCleanup);
        } on TimeoutException {
          // The durable marker remains for restart reconciliation.
        } on PairingEnrollmentUnavailableException {
          // The durable marker remains for restart reconciliation.
        } on PairingEnrollmentPersistenceException {
          // The durable marker remains for restart reconciliation.
        }
      }
    } finally {
      _activeOperation = null;
      await super.close();
    }
  }
}

enum _CleanupResume { none, resumed, failed }

final class _EnrollmentLoad {
  const _EnrollmentLoad.value(this.enrollment) : failed = false;
  const _EnrollmentLoad.failed() : enrollment = null, failed = true;
  const _EnrollmentLoad.stale() : enrollment = null, failed = false;

  final PairingEnrollment? enrollment;
  final bool failed;
}
