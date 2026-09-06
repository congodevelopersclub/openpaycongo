enum SmsAccessState { denied, permanentlyDenied, granted, unavailable }

enum CaptureFault { capacity, storage, corruption, keyInvalidated }
enum CaptureMissSignal { overload, expired }

enum NativeCaptureDecision { reviewed, rejected, processed }

final class NativeCaptureHealth {
  const NativeCaptureHealth({
    required this.fault,
    this.occurredAt,
    this.decisionCount,
    this.decisionEncryptedBytes,
    this.missed,
    this.missedAt,
    this.recoveryRequired = false,
  });
  final CaptureFault? fault;
  final DateTime? occurredAt;
  final int? decisionCount;
  final int? decisionEncryptedBytes;
  final CaptureMissSignal? missed;
  final DateTime? missedAt;
  final bool recoveryRequired;
}

final class NativeDecisionRecord {
  const NativeDecisionRecord({
    required this.id,
    required this.decision,
    required this.decidedAt,
  });
  final String id;
  final NativeCaptureDecision decision;
  final DateTime decidedAt;
}

final class NativeDecisionPage {
  const NativeDecisionPage({
    required this.records,
    required this.nextCursor,
    required this.truncated,
  });
  final List<NativeDecisionRecord> records;
  final String? nextCursor;
  final bool truncated;
}

final class NativeSmsRecord {
  const NativeSmsRecord({
    required this.id,
    required this.sender,
    required this.receivedAt,
    required this.segments,
    required this.body,
  });
  final String id;
  final String sender;
  final DateTime receivedAt;
  final int segments;
  final String body;
}

enum NativeOperatorPaymentStructure { manual, gemma4 }

final class NativeOperatorPaymentProfile {
  const NativeOperatorPaymentProfile({
    required this.sender,
    required this.provider,
    required this.structure,
    this.template,
    this.developerApprovedPatternVersion,
  });
  final String sender;
  final String provider;
  final NativeOperatorPaymentStructure structure;
  final String? template;
  /// Present only for a signed backend pattern that native storage accepted.
  final int? developerApprovedPatternVersion;
}

final class DeveloperApprovedOperatorPaymentProfile {
  const DeveloperApprovedOperatorPaymentProfile({
    required this.sender,
    required this.provider,
    required this.template,
    required this.patternVersion,
  });
  final String sender;
  final String provider;
  final String template;
  final int patternVersion;
}

enum DeveloperApprovedPatternActivation { installed, alreadyCurrent, stale }

final class DeveloperApprovedPatternActivationResult {
  const DeveloperApprovedPatternActivationResult({
    required this.activation,
    required this.profile,
  });
  final DeveloperApprovedPatternActivation activation;
  final NativeOperatorPaymentProfile profile;
}

abstract interface class SmsGatewayPort {
  Future<SmsAccessState> permissionState();
  Future<SmsAccessState> requestPermission();
  Future<void> openSettings();
  Future<int> accessGeneration();
  Future<void> setUnlocked(bool unlocked, {int? generation});
  Future<List<String>> addTrustedSender(String sender);
  Future<List<String>> listTrustedSenders();
  Future<List<String>> clearTrustedSenders();
  Future<List<String>> revokeTrustedSender(String sender);
  Future<List<NativeOperatorPaymentProfile>> upsertOperatorPaymentProfile(
    NativeOperatorPaymentProfile profile,
  );
  Future<List<NativeOperatorPaymentProfile>> listOperatorPaymentProfiles();
  Future<DeveloperApprovedPatternActivationResult>
  activateDeveloperApprovedOperatorPaymentProfile(
    DeveloperApprovedOperatorPaymentProfile profile,
  ) => throw UnimplementedError();
  Future<NativeCaptureHealth> captureHealth();
  Future<bool> probeStorage();
  Future<NativeDecisionPage> exportDecisions({int limit = 100, String? cursor});
  Future<List<NativeSmsRecord>> drainInbox();
  Future<void> commitInboxDecision(String id, NativeCaptureDecision decision);
}
