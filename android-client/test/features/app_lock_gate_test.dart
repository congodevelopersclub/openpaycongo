import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/app_lock/presentation/app_lock_bloc.dart';
import 'package:opencongopay/features/app_lock/presentation/app_lock_gate.dart';

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
