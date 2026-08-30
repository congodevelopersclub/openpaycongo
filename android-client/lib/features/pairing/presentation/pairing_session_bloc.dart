import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

enum PairingPhase { pending, active, recoveryRequired, expired }

enum PairingTelemetrySignal {
  started,
  pending,
  active,
  offline,
  recoveryRequired,
  expired,
  duplicateIgnored,
  cancelled,
}

final class PairingSession {
  const PairingSession({
    required this.sessionId,
    required this.phase,
    required this.updatedAt,
  });
  final String sessionId;
  final PairingPhase phase;
  final DateTime updatedAt;
}

abstract interface class PairingSessionStore {
  Future<PairingSession?> load();
  Future<void> save(PairingSession session);
  Future<void> clear();
}

final class PairingSessionPersistenceException implements Exception {
  const PairingSessionPersistenceException();
}

abstract interface class PairingSessionGateway {
  Future<PairingSession> begin();
  Future<PairingSession> refresh(String sessionId);
}

abstract interface class PairingTelemetry {
  void record(PairingTelemetrySignal signal);
}

sealed class PairingSessionEvent {
  const PairingSessionEvent();
}

final class PairingSessionStarted extends PairingSessionEvent {
  const PairingSessionStarted();
}

final class PairingSessionRetryRequested extends PairingSessionEvent {
  const PairingSessionRetryRequested();
}

final class PairingSessionRecovered extends PairingSessionEvent {
  const PairingSessionRecovered();
}

final class PairingSessionCancelled extends PairingSessionEvent {
  const PairingSessionCancelled();
}

sealed class PairingSessionState {
  const PairingSessionState();
}

final class PairingSessionIdle extends PairingSessionState {
  const PairingSessionIdle();
}

final class PairingSessionLoading extends PairingSessionState {
  const PairingSessionLoading();
}

final class PairingSessionPending extends PairingSessionState {
  const PairingSessionPending(this.session);
  final PairingSession session;
}

final class PairingSessionActive extends PairingSessionState {
  const PairingSessionActive(this.session);
  final PairingSession session;
}

final class PairingSessionOffline extends PairingSessionState {
  const PairingSessionOffline();
}

final class PairingSessionRecoveryRequired extends PairingSessionState {
  const PairingSessionRecoveryRequired(this.session);
  final PairingSession session;
}

final class PairingSessionExpired extends PairingSessionState {
  const PairingSessionExpired();
}

final class PairingSessionBloc
    extends Bloc<PairingSessionEvent, PairingSessionState> {
  PairingSessionBloc({
    required this.store,
    required this.gateway,
    required this.telemetry,
  }) : super(const PairingSessionIdle()) {
    on<PairingSessionStarted>(_start);
    on<PairingSessionRetryRequested>(_retry);
    on<PairingSessionRecovered>(_recover);
    on<PairingSessionCancelled>(_cancel);
  }
  final PairingSessionStore store;
  final PairingSessionGateway gateway;
  final PairingTelemetry telemetry;
  int? _activeOperation;
  int _generation = 0;
  PairingSession? _desiredSession;
  int _persistenceRevision = 0;
  Future<bool>? _cancellationCleanup;
  Future<void> _persistenceDrain = Future<void>.value();
  bool _cancellationIntent = false;
  Future<void> _start(
    PairingSessionStarted event,
    Emitter<PairingSessionState> emit,
  ) async {
    if (_activeOperation != null) {
      telemetry.record(PairingTelemetrySignal.duplicateIgnored);
      return;
    }
    _cancellationIntent = false;
    final int generation = ++_generation;
    _activeOperation = generation;
    emit(const PairingSessionLoading());
    telemetry.record(PairingTelemetrySignal.started);
    try {
      final PairingSession session = await gateway.begin();
      await _apply(session, emit, generation);
    } on TimeoutException {
      if (generation == _generation) {
        emit(const PairingSessionOffline());
        telemetry.record(PairingTelemetrySignal.offline);
      }
    } finally {
      if (_activeOperation == generation) _activeOperation = null;
    }
  }

  Future<void> _retry(
    PairingSessionRetryRequested event,
    Emitter<PairingSessionState> emit,
  ) async {
    final Future<bool>? cancellationCleanup = _cancellationCleanup;
    if (cancellationCleanup != null) {
      await cancellationCleanup;
      return;
    }
    if (_cancellationIntent) {
      await _resumeCancellation(emit);
      return;
    }
    final int observedGeneration = _generation;
    final PairingSession? session = await store.load();
    if (observedGeneration != _generation) return;
    if (session == null) {
      await _start(const PairingSessionStarted(), emit);
      return;
    }
    if (_activeOperation != null) {
      telemetry.record(PairingTelemetrySignal.duplicateIgnored);
      return;
    }
    final int generation = ++_generation;
    _activeOperation = generation;
    emit(const PairingSessionLoading());
    try {
      await _apply(await gateway.refresh(session.sessionId), emit, generation);
    } on TimeoutException {
      if (generation == _generation) {
        emit(const PairingSessionOffline());
        telemetry.record(PairingTelemetrySignal.offline);
      }
    } finally {
      if (_activeOperation == generation) _activeOperation = null;
    }
  }

  Future<void> _recover(
    PairingSessionRecovered event,
    Emitter<PairingSessionState> emit,
  ) async {
    final Future<bool>? cancellationCleanup = _cancellationCleanup;
    if (cancellationCleanup != null) {
      await cancellationCleanup;
      return;
    }
    if (_cancellationIntent) {
      await _resumeCancellation(emit);
      return;
    }
    if (_activeOperation != null) {
      telemetry.record(PairingTelemetrySignal.duplicateIgnored);
      return;
    }
    final int observedGeneration = _generation;
    final PairingSession? session = await store.load();
    if (observedGeneration != _generation) return;
    if (_activeOperation != null) {
      telemetry.record(PairingTelemetrySignal.duplicateIgnored);
      return;
    }
    if (session == null) {
      emit(const PairingSessionIdle());
      return;
    }
    final int generation = ++_generation;
    _activeOperation = generation;
    try {
      await _apply(session, emit, generation);
    } finally {
      if (_activeOperation == generation) _activeOperation = null;
    }
  }

  Future<void> _cancel(
    PairingSessionCancelled event,
    Emitter<PairingSessionState> emit,
  ) async {
    final Future<bool>? activeCleanup = _cancellationCleanup;
    if (activeCleanup != null) {
      await activeCleanup;
      return;
    }
    final int generation = ++_generation;
    _activeOperation = null;
    _cancellationIntent = true;
    _setDesiredSession(null);
    telemetry.record(PairingTelemetrySignal.cancelled);
    final Future<void> pendingPersistence = _persistenceDrain;
    final Future<bool> cleanup = _installCancellationCleanup(
      pendingPersistence,
      generation,
      emit,
    );
    final bool cleanupSucceeded = await cleanup;
    if (!cleanupSucceeded) return;
    if (generation != _generation) return;
    _cancellationIntent = false;
    emit(const PairingSessionIdle());
  }

  Future<void> _apply(
    PairingSession session,
    Emitter<PairingSessionState> emit,
    int generation,
  ) async {
    if (generation != _generation) return;
    _setDesiredSession(session);
    await _persist(() => store.save(session));
    if (generation != _generation || _desiredSession != session) {
      await _reconcileDurableSession();
      return;
    }
    switch (session.phase) {
      case PairingPhase.pending:
        emit(PairingSessionPending(session));
        telemetry.record(PairingTelemetrySignal.pending);
      case PairingPhase.active:
        emit(PairingSessionActive(session));
        telemetry.record(PairingTelemetrySignal.active);
      case PairingPhase.recoveryRequired:
        emit(PairingSessionRecoveryRequired(session));
        telemetry.record(PairingTelemetrySignal.recoveryRequired);
      case PairingPhase.expired:
        _setDesiredSession(null);
        await _reconcileDurableSession();
        if (generation != _generation) return;
        emit(const PairingSessionExpired());
        telemetry.record(PairingTelemetrySignal.expired);
    }
  }

  void _setDesiredSession(PairingSession? session) {
    _desiredSession = session;
    _persistenceRevision++;
  }

  Future<void> _reconcileDurableSession() async {
    while (true) {
      final int revision = _persistenceRevision;
      final PairingSession? session = _desiredSession;
      if (session == null) {
        await _persist(store.clear);
      } else {
        await _persist(() => store.save(session));
      }
      if (revision == _persistenceRevision) return;
    }
  }

  Future<void> _persist(Future<void> Function() operation) {
    final Future<void> result = operation();
    _persistenceDrain = Future.wait<void>(<Future<void>>[
      _persistenceDrain.catchError((Object _) {}),
      result.catchError((Object _) {}),
    ]);
    return result;
  }

  Future<bool> _finishCancellation(
    Future<void> pendingPersistence,
    int generation,
    Emitter<PairingSessionState> emit,
  ) async {
    try {
      await pendingPersistence;
      await _reconcileDurableSession();
      return true;
    } on PairingSessionPersistenceException {
      if (generation == _generation) {
        emit(const PairingSessionOffline());
        telemetry.record(PairingTelemetrySignal.offline);
      }
      return false;
    }
  }

  Future<void> _resumeCancellation(Emitter<PairingSessionState> emit) async {
    final Future<bool>? activeCleanup = _cancellationCleanup;
    if (activeCleanup != null) {
      await activeCleanup;
      return;
    }
    final int generation = _generation;
    final bool cleared = await _installCancellationCleanup(
      _persistenceDrain,
      generation,
      emit,
    );
    if (!cleared || generation != _generation) return;
    _cancellationIntent = false;
    emit(const PairingSessionIdle());
  }

  Future<bool> _installCancellationCleanup(
    Future<void> pendingPersistence,
    int generation,
    Emitter<PairingSessionState> emit,
  ) {
    late final Future<bool> cleanup;
    cleanup = _finishCancellation(pendingPersistence, generation, emit);
    _cancellationCleanup = cleanup;
    cleanup.whenComplete(() {
      if (identical(_cancellationCleanup, cleanup)) {
        _cancellationCleanup = null;
      }
    });
    return cleanup;
  }
}
