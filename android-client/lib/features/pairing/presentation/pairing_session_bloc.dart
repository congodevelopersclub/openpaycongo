import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

enum PairingPhase { pending, active, recoveryRequired, expired }
enum PairingTelemetrySignal { started, pending, active, offline, recoveryRequired, expired, duplicateIgnored, cancelled }

final class PairingSession {
  const PairingSession({required this.sessionId, required this.phase, required this.updatedAt});
  final String sessionId;
  final PairingPhase phase;
  final DateTime updatedAt;
}

abstract interface class PairingSessionStore {
  Future<PairingSession?> load();
  Future<void> save(PairingSession session);
  Future<void> clear();
}

abstract interface class PairingSessionGateway {
  Future<PairingSession> begin();
  Future<PairingSession> refresh(String sessionId);
}

abstract interface class PairingTelemetry {
  void record(PairingTelemetrySignal signal);
}

sealed class PairingSessionEvent { const PairingSessionEvent(); }
final class PairingSessionStarted extends PairingSessionEvent { const PairingSessionStarted(); }
final class PairingSessionRetryRequested extends PairingSessionEvent { const PairingSessionRetryRequested(); }
final class PairingSessionRecovered extends PairingSessionEvent { const PairingSessionRecovered(); }
final class PairingSessionCancelled extends PairingSessionEvent { const PairingSessionCancelled(); }

sealed class PairingSessionState { const PairingSessionState(); }
final class PairingSessionIdle extends PairingSessionState { const PairingSessionIdle(); }
final class PairingSessionLoading extends PairingSessionState { const PairingSessionLoading(); }
final class PairingSessionPending extends PairingSessionState { const PairingSessionPending(this.session); final PairingSession session; }
final class PairingSessionActive extends PairingSessionState { const PairingSessionActive(this.session); final PairingSession session; }
final class PairingSessionOffline extends PairingSessionState { const PairingSessionOffline(); }
final class PairingSessionRecoveryRequired extends PairingSessionState { const PairingSessionRecoveryRequired(this.session); final PairingSession session; }
final class PairingSessionExpired extends PairingSessionState { const PairingSessionExpired(); }

final class PairingSessionBloc extends Bloc<PairingSessionEvent, PairingSessionState> {
  PairingSessionBloc({required this.store, required this.gateway, required this.telemetry}) : super(const PairingSessionIdle()) {
    on<PairingSessionStarted>(_start);
    on<PairingSessionRetryRequested>(_retry);
    on<PairingSessionRecovered>(_recover);
    on<PairingSessionCancelled>(_cancel);
  }
  final PairingSessionStore store;
  final PairingSessionGateway gateway;
  final PairingTelemetry telemetry;
  bool _busy = false;
  Future<void> _start(PairingSessionStarted event, Emitter<PairingSessionState> emit) async {
    if (_busy) { telemetry.record(PairingTelemetrySignal.duplicateIgnored); return; }
    _busy = true; emit(const PairingSessionLoading()); telemetry.record(PairingTelemetrySignal.started);
    try { final PairingSession session = await gateway.begin(); await _apply(session, emit); } on TimeoutException { emit(const PairingSessionOffline()); telemetry.record(PairingTelemetrySignal.offline); } finally { _busy = false; }
  }
  Future<void> _retry(PairingSessionRetryRequested event, Emitter<PairingSessionState> emit) async {
    final PairingSession? session = await store.load();
    if (session == null) { await _start(const PairingSessionStarted(), emit); return; }
    if (_busy) { telemetry.record(PairingTelemetrySignal.duplicateIgnored); return; }
    _busy = true; emit(const PairingSessionLoading());
    try { await _apply(await gateway.refresh(session.sessionId), emit); } on TimeoutException { emit(const PairingSessionOffline()); telemetry.record(PairingTelemetrySignal.offline); } finally { _busy = false; }
  }
  Future<void> _recover(PairingSessionRecovered event, Emitter<PairingSessionState> emit) async {
    final PairingSession? session = await store.load();
    if (session == null) { emit(const PairingSessionIdle()); return; }
    await _apply(session, emit);
  }
  Future<void> _cancel(PairingSessionCancelled event, Emitter<PairingSessionState> emit) async { await store.clear(); emit(const PairingSessionIdle()); telemetry.record(PairingTelemetrySignal.cancelled); }
  Future<void> _apply(PairingSession session, Emitter<PairingSessionState> emit) async {
    await store.save(session);
    switch (session.phase) {
      case PairingPhase.pending: emit(PairingSessionPending(session)); telemetry.record(PairingTelemetrySignal.pending);
      case PairingPhase.active: emit(PairingSessionActive(session)); telemetry.record(PairingTelemetrySignal.active);
      case PairingPhase.recoveryRequired: emit(PairingSessionRecoveryRequired(session)); telemetry.record(PairingTelemetrySignal.recoveryRequired);
      case PairingPhase.expired: await store.clear(); emit(const PairingSessionExpired()); telemetry.record(PairingTelemetrySignal.expired);
    }
  }
}
