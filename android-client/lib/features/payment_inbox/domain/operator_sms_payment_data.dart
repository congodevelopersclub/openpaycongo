import '../../payment_outbox/domain/payment_outbox.dart';
import 'payment_ingestion.dart';

/// An operator-specific structure is configured outside the SMS body itself.
/// It keeps the exact sender rule and the canonical provider identity together.
final class OperatorSmsPaymentProfile {
  const OperatorSmsPaymentProfile({
    required this.provider,
    required this.senderRule,
    required this.structure,
  });

  final String provider;
  final TrustedSenderRule senderRule;
  final OperatorSmsPaymentStructure structure;
}

sealed class OperatorSmsPaymentStructure {
  const OperatorSmsPaymentStructure();
}

/// Exact, operator-maintained format. This is the normal production path.
final class ManualPaymentStructure extends OperatorSmsPaymentStructure {
  const ManualPaymentStructure(this.template);
  final PaymentTemplate template;
}

/// Optional format-change fallback. Its output always needs human confirmation.
final class Gemma4AssistedPaymentStructure extends OperatorSmsPaymentStructure {
  const Gemma4AssistedPaymentStructure();
}

sealed class OperatorSmsPaymentData {
  const OperatorSmsPaymentData();
}

final class PaymentDataReadyForPush extends OperatorSmsPaymentData {
  const PaymentDataReadyForPush(this.data);
  final CapturedPaymentForPush data;
}

final class PaymentDataNeedsReview extends OperatorSmsPaymentData {
  const PaymentDataNeedsReview(this.reason, {this.proposal});
  final String reason;
  final Gemma4PaymentProposal? proposal;
}

/// The complete local data contract for the independently-owned push worker.
/// No queue, network request, or native inbox acknowledgement happens here.
final class CapturedPaymentForPush {
  const CapturedPaymentForPush({
    required this.sourceRecordId,
    required this.envelope,
    required this.provenance,
  });
  final String sourceRecordId;
  final PaymentEnvelope envelope;
  final PaymentParserProvenance provenance;
}

/// Attribution travels with the local push-ready data; it lets the separate
/// push owner audit exactly which local parsing authority created the value.
final class PaymentParserProvenance {
  const PaymentParserProvenance.manualConfiguration()
      : kind = PaymentParserKind.manualConfiguration,
        approvedPatternVersion = null;

  const PaymentParserProvenance.developerApprovedPattern(
    int patternVersion,
  )   : assert(patternVersion > 0),
        kind = PaymentParserKind.developerApprovedPattern,
        approvedPatternVersion = patternVersion;

  const PaymentParserProvenance.userConfirmedGemma4()
      : kind = PaymentParserKind.userConfirmedGemma4,
        approvedPatternVersion = null;

  final PaymentParserKind kind;
  final int? approvedPatternVersion;
}

enum PaymentParserKind {
  manualConfiguration,
  developerApprovedPattern,
  userConfirmedGemma4,
}

final class OperatorSmsPaymentDataFactory {
  const OperatorSmsPaymentDataFactory();

  OperatorSmsPaymentData interpret({
    required String sourceRecordId,
    required SmsEnvelope sms,
    required OperatorSmsPaymentProfile profile,
    required OutboxScope scope,
    PaymentParserProvenance provenance =
        const PaymentParserProvenance.manualConfiguration(),
  }) {
    if (!_validSourceId(sourceRecordId) || !_validProfile(profile)) {
      return const PaymentDataNeedsReview('invalid_operator_payment_profile');
    }
    final OperatorSmsPaymentStructure structure = profile.structure;
    if (structure is! ManualPaymentStructure) {
      return const PaymentDataNeedsReview('manual_structure_not_configured');
    }
    final ParseDecision decision = const DeterministicPaymentParser().parse(
      sms,
      profile.senderRule,
      structure.template,
    );
    if (decision is! TrustedCandidate) {
      return PaymentDataNeedsReview(_reasonFor(decision));
    }
    return _ready(
      sourceRecordId: sourceRecordId,
      candidate: decision.value,
      capturedAt: sms.receivedAt,
      profile: profile,
      scope: scope,
      provenance: provenance,
    );
  }
}

/// Bounded Gemma 4 proposal integration. The runner is injected so platform
/// model packaging and capability checks remain outside this domain boundary.
final class Gemma4PaymentDataFactory {
  Gemma4PaymentDataFactory(this._runner);
  final BoundedProposalRunner _runner;

  Future<OperatorSmsPaymentData> propose({
    required String sourceRecordId,
    required SmsEnvelope sms,
    required OperatorSmsPaymentProfile profile,
    required OutboxScope scope,
  }) async {
    if (!_validSourceId(sourceRecordId) || !_validProfile(profile)) {
      return const PaymentDataNeedsReview('invalid_operator_payment_profile');
    }
    if (profile.structure is! Gemma4AssistedPaymentStructure) {
      return const PaymentDataNeedsReview('gemma4_structure_not_configured');
    }
    final ParseDecision decision = await _runner.run(sms, profile.senderRule);
    if (decision is! NeedsReview || decision.candidate == null) {
      return PaymentDataNeedsReview(_reasonFor(decision));
    }
    return PaymentDataNeedsReview(
      decision.reason,
      proposal: Gemma4PaymentProposal._(
        sourceRecordId: sourceRecordId,
        candidate: decision.candidate!,
        capturedAt: sms.receivedAt,
        profile: profile,
        scope: scope,
      ),
    );
  }

  OperatorSmsPaymentData confirm(
    Gemma4PaymentProposal proposal, {
    required bool confirmedByUser,
  }) {
    if (!confirmedByUser) {
      return const PaymentDataNeedsReview('user_confirmation_required');
    }
    return _ready(
      sourceRecordId: proposal.sourceRecordId,
      candidate: proposal.candidate,
      capturedAt: proposal.capturedAt,
      profile: proposal.profile,
      scope: proposal.scope,
      provenance: const PaymentParserProvenance.userConfirmedGemma4(),
    );
  }
}

final class Gemma4PaymentProposal {
  const Gemma4PaymentProposal._({
    required this.sourceRecordId,
    required this.candidate,
    required this.capturedAt,
    required this.profile,
    required this.scope,
  });
  final String sourceRecordId;
  final PaymentCandidate candidate;
  final DateTime capturedAt;
  final OperatorSmsPaymentProfile profile;
  final OutboxScope scope;
}

OperatorSmsPaymentData _ready({
  required String sourceRecordId,
  required PaymentCandidate candidate,
  required DateTime capturedAt,
  required OperatorSmsPaymentProfile profile,
  required OutboxScope scope,
  required PaymentParserProvenance provenance,
}) {
  final PaymentEnvelope? envelope = PaymentEnvelope.create(
    scope: scope,
    provider: profile.provider,
    providerReference: candidate.reference,
    amountMinor: candidate.amountMinor,
    currency: candidate.currency,
    capturedAt: capturedAt,
  );
  if (envelope == null) {
    return const PaymentDataNeedsReview('invalid_payment_data');
  }
  return PaymentDataReadyForPush(
    CapturedPaymentForPush(
      sourceRecordId: sourceRecordId,
      envelope: envelope,
      provenance: provenance,
    ),
  );
}

bool _validProfile(OperatorSmsPaymentProfile profile) =>
    RegExp(r'^[A-Z0-9._-]{3,32}$').hasMatch(profile.provider) &&
    switch (profile.structure) {
      ManualPaymentStructure(:final PaymentTemplate template) => template.valid,
      Gemma4AssistedPaymentStructure() => true,
    };

bool _validSourceId(String value) => RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

String _reasonFor(ParseDecision decision) => switch (decision) {
  Rejected(:final String reason) => reason,
  NeedsReview(:final String reason) => reason,
  TrustedCandidate() => 'unexpected_trusted_candidate',
};
