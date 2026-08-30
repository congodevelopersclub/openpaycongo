import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_enrollment_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_enrollment_status_card.dart';

void main() {
  testWidgets('renders empty enrollment state', (WidgetTester tester) async {
    final PairingEnrollmentBloc bloc = _bloc();
    addTearDown(bloc.close);
    await tester.pumpWidget(_card(bloc));

    expect(find.text('No pairing enrollment'), findsOneWidget);
  });

  testWidgets('renders loading then pending enrollment success', (
    WidgetTester tester,
  ) async {
    final Completer<PairingEnrollment> pending = Completer<PairingEnrollment>();
    final PairingEnrollmentBloc bloc = _bloc(begin: () => pending.future);
    addTearDown(bloc.close);
    await tester.pumpWidget(_card(bloc));
    bloc.add(const PairingEnrollmentStarted());
    await tester.pump();
    expect(find.text('Pairing enrollment in progress'), findsOneWidget);

    pending.complete(_enrollment(PairingEnrollmentPhase.pendingConfirmation));
    await tester.pumpAndSettle();
    expect(find.text('Pairing enrollment awaits confirmation'), findsOneWidget);
    expect(find.text('Cancel pairing enrollment'), findsOneWidget);

    await tester.tap(find.text('Cancel pairing enrollment'));
    await tester.pumpAndSettle();
    expect(find.text('No pairing enrollment'), findsOneWidget);
  });

  testWidgets('renders offline and dispatches retry intent', (
    WidgetTester tester,
  ) async {
    int attempts = 0;
    final PairingEnrollmentBloc bloc = _bloc(
      begin: () async {
        attempts++;
        if (attempts == 1) throw TimeoutException('offline');
        return _enrollment(PairingEnrollmentPhase.active);
      },
    );
    addTearDown(bloc.close);
    await tester.pumpWidget(_card(bloc));
    bloc.add(const PairingEnrollmentStarted());
    await tester.pumpAndSettle();
    expect(find.text('Pairing enrollment offline'), findsOneWidget);

    await tester.pump();
    await tester.tap(find.text('Retry pairing enrollment'));
    await tester.pumpAndSettle();
    expect(find.text('Pairing enrollment active'), findsOneWidget);
  });

  testWidgets('renders terminal error and recovery action', (
    WidgetTester tester,
  ) async {
    final PairingEnrollmentBloc error = _bloc(
      begin: () async => throw const PairingEnrollmentProtocolException(),
    );
    addTearDown(error.close);
    await tester.pumpWidget(_card(error));
    error.add(const PairingEnrollmentStarted());
    await tester.pumpAndSettle();
    expect(find.text('Pairing enrollment needs a new QR'), findsOneWidget);
    expect(find.text('Cancel pairing enrollment'), findsOneWidget);

    final PairingEnrollment recovery = _enrollment(
      PairingEnrollmentPhase.recoveryRequired,
    );
    final PairingEnrollmentBloc recovering = PairingEnrollmentBloc(
      store: _Store()..value = recovery,
      transport: _Transport(recovery),
      telemetry: _Telemetry(),
    );
    addTearDown(recovering.close);
    await tester.pumpWidget(_card(recovering));
    recovering.add(const PairingEnrollmentRecovered());
    await tester.pumpAndSettle();
    expect(find.text('Pairing enrollment recovery required'), findsOneWidget);
    expect(find.text('Recover pairing enrollment'), findsOneWidget);
  });
}

Widget _card(PairingEnrollmentBloc bloc) => MaterialApp(
  home: BlocProvider<PairingEnrollmentBloc>.value(
    value: bloc,
    child: const Scaffold(body: PairingEnrollmentStatusCard()),
  ),
);

PairingEnrollmentBloc _bloc({Future<PairingEnrollment> Function()? begin}) =>
    PairingEnrollmentBloc(
      store: _Store(),
      transport: _Transport(
        _enrollment(PairingEnrollmentPhase.pendingConfirmation),
        beginResult: begin,
      ),
      telemetry: _Telemetry(),
    );

PairingEnrollment _enrollment(PairingEnrollmentPhase phase) =>
    PairingEnrollment(phase: phase, updatedAt: DateTime.utc(2026, 8, 30));

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
  const _Transport(this.result, {this.beginResult});

  final PairingEnrollment result;
  final Future<PairingEnrollment> Function()? beginResult;

  @override
  Future<PairingEnrollment> begin() =>
      beginResult?.call() ?? Future.value(result);

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      result;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async => result;

  @override
  Future<void> discardTerminal() async {}
}

final class _Telemetry implements PairingEnrollmentTelemetryPort {
  @override
  void record(PairingEnrollmentTelemetry signal) {}
}
