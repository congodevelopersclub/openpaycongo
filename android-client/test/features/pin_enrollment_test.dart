import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/app_lock/domain/pin_enrollment.dart';

final class ProvisionerFake implements PinVerifierProvisioner {
  ProvisionerFake({this.shouldFail = false});

  final bool shouldFail;
  int calls = 0;

  @override
  Future<void> provision(String pin) async {
    calls++;
    if (shouldFail) throw StateError('secure verifier unavailable');
  }
}

void main() {
  test('invalid or mismatched first-launch PIN never reaches the provisioner', () async {
    final ProvisionerFake provisioner = ProvisionerFake();
    final PinEnrollmentService service = PinEnrollmentService(provisioner);

    expect((await service.enroll(pin: '12345', confirmation: '12345')).status, PinEnrollmentStatus.invalidPin);
    expect((await service.enroll(pin: '123456', confirmation: '654321')).status, PinEnrollmentStatus.confirmationMismatch);
    expect(provisioner.calls, 0);
  });

  test('exact six-digit confirmation provisions once without retaining PIN state', () async {
    final ProvisionerFake provisioner = ProvisionerFake();
    final PinEnrollmentResult result = await PinEnrollmentService(provisioner).enroll(
      pin: '123456',
      confirmation: '123456',
    );

    expect(result.isProvisioned, isTrue);
    expect(provisioner.calls, 1);
  });

  test('secure provisioner failure stays explicit and fails closed', () async {
    final ProvisionerFake provisioner = ProvisionerFake(shouldFail: true);

    final PinEnrollmentResult result = await PinEnrollmentService(provisioner).enroll(
      pin: '123456',
      confirmation: '123456',
    );

    expect(result.status, PinEnrollmentStatus.provisioningFailed);
    expect(provisioner.calls, 1);
  });
}
