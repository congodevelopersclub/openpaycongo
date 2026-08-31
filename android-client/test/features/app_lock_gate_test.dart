import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/app_lock/presentation/app_lock_bloc.dart';
import 'package:opencongopay/features/app_lock/presentation/app_lock_gate.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_verification_screen.dart';

void main() {
  testWidgets(
    'protected content is absent until BLoC unlock and removed on background',
    (WidgetTester tester) async {
      final _Port port = _Port();
      final AppLockBloc bloc = AppLockBloc(port: port);
      addTearDown(bloc.close);
      int protectedBuilds = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: AppLockGate(
            bloc: bloc,
            protectedBuilder: (BuildContext context) {
              protectedBuilds++;
              return const Text('private payment content');
            },
          ),
        ),
      );
      await tester.pump();
      expect(protectedBuilds, 0);
      expect(find.text('private payment content'), findsNothing);

      await tester.tap(find.text('Use biometrics'));
      await tester.pump();
      await tester.pump();
      expect(protectedBuilds, greaterThanOrEqualTo(1));
      expect(find.text('private payment content'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump();
      expect(port.lockCalls, 1);
      expect(find.text('private payment content'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background locks during a scanner call and safe scanner result survives for normal unlock',
    (WidgetTester tester) async {
      const String rawQr = '{"untrusted":"raw QR must not render"}';
      final _Port port = _Port();
      final AppLockBloc lock = AppLockBloc(port: port);
      final _DeferredScanner scanner = _DeferredScanner();
      final PairingQrBloc pairing = PairingQrBloc(
        trustStore: const _TrustStore(),
        scanner: scanner,
      );
      addTearDown(lock.close);
      addTearDown(pairing.close);

      await tester.pumpWidget(
        MaterialApp(
          home: AppLockGate(
            bloc: lock,
            protectedBuilder: (_) => PairingQrVerificationScreen(bloc: pairing),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Use biometrics'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Scan pairing QR code'));
      await tester.pump();
      expect(scanner.started.isCompleted, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump();
      expect(port.lockCalls, 1);
      expect(find.bySemanticsLabel('Scan pairing QR code'), findsNothing);

      scanner.complete(rawQr);
      await tester.pump();
      await tester.pump();
      expect(pairing.state, isA<PairingQrRejected>());
      expect(pairing.state.toString(), isNot(contains(rawQr)));

      await tester.tap(find.text('Use biometrics'));
      await tester.pump();
      await tester.pump();
      expect(find.text('This QR code cannot be verified.'), findsOneWidget);
      expect(find.textContaining(rawQr), findsNothing);
    },
  );
}

final class _Port implements AppLockPort {
  int lockCalls = 0;

  @override
  Future<AppLockStatus> status() async => const AppLockStatus.ready();

  @override
  Future<AppLockEnrollmentResult> enroll(String pin) async =>
      const AppLockEnrollmentResult.provisioned();

  @override
  Future<AppLockPinResult> verifyPin(String pin) async =>
      const AppLockPinResult.unlocked();

  @override
  Future<AppLockBiometricResult> verifyBiometric() async =>
      const AppLockBiometricResult.unlocked();

  @override
  Future<void> lockNativeBridge() async {
    lockCalls++;
  }

  @override
  Future<void> unlockNativeBridge() async {}
}

final class _DeferredScanner implements PairingQrScanner {
  final Completer<void> started = Completer<void>();
  final Completer<String?> _result = Completer<String?>();

  @override
  Future<String?> scan() {
    started.complete();
    return _result.future;
  }

  void complete(String? value) => _result.complete(value);
}

final class _TrustStore implements PairingQrTrustStore {
  const _TrustStore();

  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.matching();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.alreadyStored();
}
