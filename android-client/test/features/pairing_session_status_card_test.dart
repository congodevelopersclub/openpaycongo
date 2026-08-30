import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_session_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_session_status_card.dart';

void main() {
  testWidgets('renders pending pairing state from BLoC', (tester) async {
    final bloc = PairingSessionBloc(
      store: _Store(),
      gateway: _Gateway(),
      telemetry: _Telemetry(),
    );
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: bloc,
          child: const PairingSessionStatusCard(),
        ),
      ),
    );
    bloc.add(const PairingSessionStarted());
    await tester.pumpAndSettle();
    expect(find.text('Pairing awaits confirmation'), findsOneWidget);
  });
}

final class _Store implements PairingSessionStore {
  @override
  Future<void> clear() async {}
  @override
  Future<PairingSession?> load() async => null;
  @override
  Future<void> save(PairingSession session) async {}
}

final class _Gateway implements PairingSessionGateway {
  final session = PairingSession(
    sessionId: 'opaque',
    phase: PairingPhase.pending,
    updatedAt: DateTime.utc(2026),
  );
  @override
  Future<PairingSession> begin() async => session;
  @override
  Future<PairingSession> refresh(String sessionId) async => session;
}

final class _Telemetry implements PairingTelemetry {
  @override
  void record(PairingTelemetrySignal signal) {}
}
