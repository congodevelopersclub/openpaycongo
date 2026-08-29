import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_session_bloc.dart';
void main() {
  test('persists opaque pending pairing and recovers it after restart', () async {
    final _Store store = _Store(); final _Telemetry telemetry = _Telemetry();
    final PairingSession session = PairingSession(sessionId: 'opaque-session-1', phase: PairingPhase.pending, updatedAt: DateTime.utc(2026));
    final PairingSessionBloc bloc = PairingSessionBloc(store: store, gateway: _Gateway(session), telemetry: telemetry);
    final Future<void> states = expectLater(bloc.stream, emitsInOrder(<Matcher>[isA<PairingSessionLoading>(), isA<PairingSessionPending>()]));
    bloc.add(const PairingSessionStarted()); await states; await bloc.close();
    final PairingSessionBloc restarted = PairingSessionBloc(store: store, gateway: _Gateway(session), telemetry: telemetry);
    final Future<void> recovered = expectLater(restarted.stream, emits(isA<PairingSessionPending>()));
    restarted.add(const PairingSessionRecovered()); await recovered; expect(telemetry.signals, contains(PairingTelemetrySignal.pending)); await restarted.close();
  });
  test('timeout stays offline and duplicate start does not create a second request', () async {
    final _Store store = _Store(); final _Telemetry telemetry = _Telemetry(); final _Gateway gateway = _Gateway(null, timeout: true);
    final PairingSessionBloc bloc = PairingSessionBloc(store: store, gateway: gateway, telemetry: telemetry);
    final Future<void> states = expectLater(bloc.stream, emitsInOrder(<Matcher>[isA<PairingSessionLoading>(), isA<PairingSessionOffline>()]));
    bloc..add(const PairingSessionStarted())..add(const PairingSessionStarted()); await states; expect(gateway.calls, 1); expect(telemetry.signals, contains(PairingTelemetrySignal.duplicateIgnored)); await bloc.close();
  });
}
final class _Store implements PairingSessionStore { PairingSession? value; @override Future<void> clear() async { value = null; } @override Future<PairingSession?> load() async => value; @override Future<void> save(PairingSession session) async { value = session; } }
final class _Gateway implements PairingSessionGateway { _Gateway(this.value,{this.timeout=false}); final PairingSession? value; final bool timeout; int calls=0; @override Future<PairingSession> begin() async { calls++; if(timeout) { await Future<void>.delayed(const Duration(milliseconds: 10)); throw TimeoutException('offline'); } return value!; } @override Future<PairingSession> refresh(String sessionId) => begin(); }
final class _Telemetry implements PairingTelemetry { final List<PairingTelemetrySignal> signals=[]; @override void record(PairingTelemetrySignal signal)=>signals.add(signal); }
