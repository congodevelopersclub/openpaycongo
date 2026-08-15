/// A production adapter derives and protects a verifier from this transient
/// value. It must never persist the PIN itself.
abstract interface class PinVerifierProvisioner {
  Future<void> provision(String pin);
}

enum PinEnrollmentStatus { readyForEntry, invalidPin, confirmationMismatch, provisioningFailed, provisioned }

final class PinEnrollmentResult {
  const PinEnrollmentResult(this.status);

  final PinEnrollmentStatus status;
  bool get isProvisioned => status == PinEnrollmentStatus.provisioned;
}

/// First-launch setup policy for the mandatory local lock.
///
/// It deliberately owns no PIN state. The caller supplies both fields for one
/// attempt, and only a valid exact match reaches the injected secure verifier
/// provisioner.
final class PinEnrollmentService {
  const PinEnrollmentService(this._provisioner);

  final PinVerifierProvisioner _provisioner;

  Future<PinEnrollmentResult> enroll({required String pin, required String confirmation}) async {
    if (!_isSixDigitPin(pin) || !_isSixDigitPin(confirmation)) {
      return const PinEnrollmentResult(PinEnrollmentStatus.invalidPin);
    }
    if (pin != confirmation) {
      return const PinEnrollmentResult(PinEnrollmentStatus.confirmationMismatch);
    }
    try {
      await _provisioner.provision(pin);
      return const PinEnrollmentResult(PinEnrollmentStatus.provisioned);
    } on Object {
      return const PinEnrollmentResult(PinEnrollmentStatus.provisioningFailed);
    }
  }

  static bool _isSixDigitPin(String value) => RegExp(r'^[0-9]{6}$').hasMatch(value);
}
