/// Read-only evidence supplied by independently verified product seams.
///
/// This deliberately has no network or credential capability. A later
/// operational probe may refine [SyncDiagnosisCode.checkingReadiness], but
/// cannot turn missing authority or durable evidence into a ready claim.
final class SyncCapabilityEvidence {
  const SyncCapabilityEvidence({
    required this.identityAuthorityApproved,
    required this.transportAvailable,
    required this.durableOutboxTested,
    required this.acknowledgementAvailable,
  });

  final bool identityAuthorityApproved;
  final bool transportAvailable;
  final bool durableOutboxTested;
  final bool acknowledgementAvailable;
}

enum SyncDiagnosisCode {
  identityAuthorityUnapproved,
  transportUnavailable,
  durableOutboxUnverified,
  acknowledgementUnavailable,
  checkingReadiness,
}

/// A fail-closed mobile-facing diagnosis. No state denotes server-confirmed
/// payment delivery: that requires a distinct authenticated acknowledgement.
final class SyncDiagnosis {
  const SyncDiagnosis._(this.code, this.title, this.detail);

  final SyncDiagnosisCode code;
  final String title;
  final String detail;

  bool get localCaptureAvailable => true;
  bool get serverAcknowledgementAvailable => false;
  bool get needsOperationalProbe => code == SyncDiagnosisCode.checkingReadiness;

  static SyncDiagnosis fromEvidence(SyncCapabilityEvidence evidence) {
    if (!evidence.identityAuthorityApproved) {
      return const SyncDiagnosis._(
        SyncDiagnosisCode.identityAuthorityUnapproved,
        'Server sync unavailable',
        'Local capture remains available. Server acknowledgement is unavailable until identity authority is approved.',
      );
    }
    if (!evidence.transportAvailable) {
      return const SyncDiagnosis._(
        SyncDiagnosisCode.transportUnavailable,
        'Server sync unavailable',
        'Local capture remains available. The approved sync transport is not available.',
      );
    }
    if (!evidence.durableOutboxTested) {
      return const SyncDiagnosis._(
        SyncDiagnosisCode.durableOutboxUnverified,
        'Server sync unavailable',
        'Local capture remains available. Durable outbox evidence is not available.',
      );
    }
    if (!evidence.acknowledgementAvailable) {
      return const SyncDiagnosis._(
        SyncDiagnosisCode.acknowledgementUnavailable,
        'Server sync unavailable',
        'Local capture remains available. Server acknowledgement is not available.',
      );
    }
    return const SyncDiagnosis._(
      SyncDiagnosisCode.checkingReadiness,
      'Checking server readiness',
      'Local capture remains available. No payment is confirmed until an authenticated server acknowledgement is stored.',
    );
  }
}
