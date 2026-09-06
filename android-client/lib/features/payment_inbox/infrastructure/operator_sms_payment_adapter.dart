import '../../payment_outbox/domain/payment_outbox.dart';
import '../../sms_gateway/domain/sms_gateway.dart';
import '../domain/operator_sms_payment_data.dart';
import '../domain/payment_ingestion.dart';

/// Converts guarded native inbox/profile records into the pure payment-data
/// boundary. The caller supplies its authenticated outbox scope; this adapter
/// neither commits an inbox decision nor sends anything.
final class OperatorSmsPaymentAdapter {
  const OperatorSmsPaymentAdapter({this.now = _systemNow});

  final DateTime Function() now;

  OperatorSmsPaymentData interpret({
    required NativeSmsRecord record,
    required NativeOperatorPaymentProfile profile,
    required OutboxScope scope,
  }) {
    final OperatorSmsPaymentProfile? configured = _profile(profile);
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(record.sender);
    final SmsEnvelope? sms = sender == null
        ? null
        : SmsEnvelope.fromOs(
            sender: sender,
            body: record.body,
            receivedAt: record.receivedAt,
            segments: record.segments,
            now: now(),
          );
    if (configured == null || sms == null || profile.sender != record.sender) {
      return const PaymentDataNeedsReview('invalid_native_operator_payment_data');
    }
    return switch (configured.structure) {
      ManualPaymentStructure() => const OperatorSmsPaymentDataFactory().interpret(
        sourceRecordId: record.id,
        sms: sms,
        profile: configured,
        scope: scope,
        provenance: profile.developerApprovedPatternVersion == null
            ? const PaymentParserProvenance.manualConfiguration()
            : PaymentParserProvenance.developerApprovedPattern(
                profile.developerApprovedPatternVersion!,
              ),
      ),
      Gemma4AssistedPaymentStructure() =>
        const PaymentDataNeedsReview('gemma4_proposal_required'),
    };
  }

  /// Runs the supplied on-device model only for a Gemma 4 profile. Its output
  /// remains a review proposal: it cannot queue, send, or acknowledge data.
  Future<OperatorSmsPaymentData> interpretWithGemma({
    required NativeSmsRecord record,
    required NativeOperatorPaymentProfile profile,
    required OutboxScope scope,
    required Gemma4PaymentDataFactory factory,
  }) async {
    final OperatorSmsPaymentProfile? configured = _profile(profile);
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(record.sender);
    final SmsEnvelope? sms = sender == null
        ? null
        : SmsEnvelope.fromOs(
            sender: sender,
            body: record.body,
            receivedAt: record.receivedAt,
            segments: record.segments,
            now: now(),
          );
    if (configured == null || sms == null || profile.sender != record.sender) {
      return const PaymentDataNeedsReview('invalid_native_operator_payment_data');
    }
    if (configured.structure is! Gemma4AssistedPaymentStructure) {
      return const PaymentDataNeedsReview('gemma4_structure_not_configured');
    }
    return factory.propose(
      sourceRecordId: record.id,
      sms: sms,
      profile: configured,
      scope: scope,
    );
  }

  OperatorSmsPaymentProfile? _profile(NativeOperatorPaymentProfile profile) {
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(profile.sender);
    if (sender == null) return null;
    final OperatorSmsPaymentStructure? structure = switch (profile.structure) {
      NativeOperatorPaymentStructure.manual when profile.template != null =>
        ManualPaymentStructure(PaymentTemplate(profile.template!)),
      NativeOperatorPaymentStructure.gemma4 when profile.template == null =>
        const Gemma4AssistedPaymentStructure(),
      _ => null,
    };
    if (structure == null) return null;
    return OperatorSmsPaymentProfile(
      provider: profile.provider,
      senderRule: TrustedSenderRule(sender),
      structure: structure,
    );
  }
}

DateTime _systemNow() => DateTime.now().toUtc();
