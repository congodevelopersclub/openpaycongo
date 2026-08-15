import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/app_lock/domain/app_lock.dart';

final class FakeAuthenticator implements LocalAppAuthenticator {
  FakeAuthenticator(this.results);

  final List<bool> results;
  int calls = 0;

  @override
  Future<bool> authenticate() async => results[calls++];
}

final class FakePinVerifier implements LocalPinVerifier {
  FakePinVerifier(this.accepted);

  bool accepted;
  int calls = 0;

  @override
  Future<bool> verify(String pin) async {
    calls++;
    return accepted;
  }
}

void main() {
  final DateTime now = DateTime.utc(2026, 8, 15, 10);

  test('cold start and process restart fail closed until a local verifier succeeds', () async {
    final FakeAuthenticator authenticator = FakeAuthenticator(<bool>[true]);
    final FakePinVerifier pin = FakePinVerifier(true);
    final AppLockController controller = AppLockController(
      authenticator: authenticator,
      pinVerifier: pin,
    );

    expect(controller.snapshot.state, AppLockState.locked);
    expect(controller.snapshot.reason, AppLockReason.coldStart);
    await controller.unlockWithPin('1234', now);
    expect(controller.snapshot.state, AppLockState.unlocked);
    expect(pin.calls, 1);

    final AppLockController restarted = AppLockController(
      authenticator: authenticator,
      pinVerifier: pin,
    );
    expect(restarted.snapshot.state, AppLockState.locked);
    expect(restarted.snapshot.reason, AppLockReason.coldStart);
  });

  test('background hides an unlocked app and resumed timeout remains fail closed', () async {
    final AppLockController controller = AppLockController(
      authenticator: FakeAuthenticator(<bool>[true]),
      pinVerifier: FakePinVerifier(false),
      backgroundTimeout: const Duration(minutes: 2),
    );
    await controller.authenticate(now);
    expect(controller.snapshot.state, AppLockState.unlocked);

    controller.background(now);
    expect(controller.snapshot.state, AppLockState.locked);
    expect(controller.snapshot.reason, AppLockReason.background);
    controller.resume(now.add(const Duration(minutes: 3)));
    expect(controller.snapshot.state, AppLockState.locked);
    expect(controller.snapshot.reason, AppLockReason.backgroundTimeout);
  });

  test('failures back off, are bounded, and enter explicit lockout', () async {
    final FakeAuthenticator authenticator = FakeAuthenticator(<bool>[false, false]);
    final AppLockController controller = AppLockController(
      authenticator: authenticator,
      pinVerifier: FakePinVerifier(false),
      maxFailures: 2,
    );

    await controller.authenticate(now);
    expect(controller.snapshot.state, AppLockState.backoff);
    expect(controller.snapshot.failures, 1);
    expect(controller.snapshot.nextAttemptAt, now.add(const Duration(minutes: 1)));
    await controller.authenticate(now);
    expect(authenticator.calls, 1);

    await controller.authenticate(now.add(const Duration(minutes: 1)));
    expect(controller.snapshot.state, AppLockState.lockedOut);
    expect(controller.snapshot.reason, AppLockReason.lockout);
    await controller.authenticate(now.add(const Duration(hours: 1)));
    expect(authenticator.calls, 2);
  });

  test('cancellation restores the locked state without treating it as a verifier failure', () async {
    final AppLockController controller = AppLockController(
      authenticator: FakeAuthenticator(<bool>[true]),
      pinVerifier: FakePinVerifier(false),
    );

    controller.cancel();

    expect(controller.snapshot.state, AppLockState.locked);
    expect(controller.snapshot.reason, AppLockReason.cancelled);
    expect(controller.snapshot.failures, 0);
  });
}
