import 'dart:typed_data';

import '../../payment_outbox/domain/payment_outbox.dart';
import '../../sms_gateway/domain/sms_gateway.dart';
import '../domain/approved_operator_pattern.dart';
import '../domain/operator_sms_payment_data.dart';
import '../domain/payment_ingestion.dart';
import 'operator_sms_analysis_envelope_transport.dart';
import 'operator_sms_payment_adapter.dart';

/// The sole read boundary the separately-owned push worker needs. It joins the
/// authoritative encrypted inbox with its persisted operator profile, creates
/// immutable push-ready data when possible, and never acknowledges an SMS.
final class OperatorSmsPaymentDataSource {
  OperatorSmsPaymentDataSource({
    required this.gateway,
    this.adapter = const OperatorSmsPaymentAdapter(),
  });

  final SmsGatewayPort gateway;
  final OperatorSmsPaymentAdapter adapter;

  Future<List<OperatorSmsPaymentData>> read(OutboxScope scope) async {
    final List<NativeOperatorPaymentProfile> profiles =
        await gateway.listOperatorPaymentProfiles();
    final Map<String, NativeOperatorPaymentProfile> bySender =
        <String, NativeOperatorPaymentProfile>{};
    for (final NativeOperatorPaymentProfile profile in profiles) {
      if (bySender.containsKey(profile.sender)) {
        throw const FormatException('duplicate_operator_payment_profile');
      }
      bySender[profile.sender] = profile;
    }
    final List<NativeSmsRecord> records = await gateway.drainInbox();
    final List<OperatorSmsPaymentData> data = <OperatorSmsPaymentData>[];
    for (final NativeSmsRecord record in records) {
      final NativeOperatorPaymentProfile? profile = bySender[record.sender];
      if (profile == null) {
        data.add(const PaymentDataNeedsReview('operator_payment_profile_missing'));
        continue;
      }
      // No raw SMS is ever sent to an on-device or third-party model here.
      // A legacy Gemma profile remains review-only until a separately delivered,
      // developer-approved signed backend pattern is verified and reanalysed.
      data.add(adapter.interpret(record: record, profile: profile, scope: scope));
    }
    return List<OperatorSmsPaymentData>.unmodifiable(data);
  }

  /// Sends one retained SMS only after a user has explicitly consented from
  /// the protected review screen. This creates review evidence, never a
  /// payment or parser activation; the backend can only propose a pattern for
  /// developer approval.
  Future<OperatorSmsAnalysisSubmission> submitFailedSmsForAnalysis({
    required String sourceRecordId,
    required bool userConfirmed,
    required DateTime now,
    required OperatorSmsAnalysisEnvelopeTransport transport,
  }) async {
    if (!userConfirmed) {
      throw StateError('operator_sms_analysis_consent_required');
    }
    final List<NativeSmsRecord> records = await gateway.drainInbox();
    NativeSmsRecord? record;
    for (final NativeSmsRecord value in records) {
      if (value.id == sourceRecordId) {
        record = value;
        break;
      }
    }
    if (record == null) throw StateError('operator_sms_record_unavailable');
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(record.sender);
    final SmsEnvelope? envelope = sender == null
        ? null
        : SmsEnvelope.fromOs(
            sender: sender,
            body: record.body,
            receivedAt: record.receivedAt,
            segments: record.segments,
            now: now,
          );
    if (envelope == null) {
      throw StateError('operator_sms_record_invalid');
    }
    final List<NativeOperatorPaymentProfile> profiles =
        await gateway.listOperatorPaymentProfiles();
    NativeOperatorPaymentProfile? profile;
    for (final NativeOperatorPaymentProfile value in profiles) {
      if (value.sender == record.sender) {
        profile = value;
        break;
      }
    }
    if (profile == null) {
      throw StateError('operator_sms_provider_unconfigured');
    }
    return transport.submit(
      OperatorSmsAnalysisEvidence(
        recordId: record.id,
        provider: profile.provider,
        sender: sender!.value,
        body: envelope.body,
        receivedAt: envelope.receivedAt,
      ),
    );
  }

  /// The independently-owned release delivery worker calls this with one
  /// backend-published release. Native storage is the monotonic authority: an
  /// older (or conflicting same-version) release cannot replace an activated
  /// developer-approved parser. This never acknowledges an SMS.
  Future<PatternReleaseDelivery> reanalyseRelease({
    required String encodedRelease,
    required Uint8List pinnedSigningKey,
    required DateTime now,
    required OutboxScope scope,
  }) async {
    final DeveloperApprovedOperatorPaymentPattern? release =
        await const DeveloperApprovedOperatorPaymentPatternVerifier().verify(
      encodedRelease: encodedRelease,
      pinnedSigningKey: pinnedSigningKey,
      now: now,
    );
    if (release == null) {
      return const PatternReleaseRejected('invalid_or_expired_release');
    }

    final DeveloperApprovedPatternActivationResult activation =
        await gateway.activateDeveloperApprovedOperatorPaymentProfile(
      DeveloperApprovedOperatorPaymentProfile(
        sender: release.proposal.sender,
        provider: release.proposal.provider,
        template: release.proposal.template,
        patternVersion: release.proposal.version,
      ),
    );
    if (activation.activation == DeveloperApprovedPatternActivation.stale) {
      return const PatternReleaseRejected('stale_approved_pattern_release');
    }

    final SenderIdentity sender =
        SenderIdentity.fromOsMetadata(release.proposal.sender)!;
    final TrustedSenderRule senderRule = TrustedSenderRule(sender);
    final List<PendingOperatorSms> pending = <PendingOperatorSms>[];
    final List<PendingPatternReview> invalid = <PendingPatternReview>[];
    for (final NativeSmsRecord record in await gateway.drainInbox()) {
      final SenderIdentity? recordSender =
          SenderIdentity.fromOsMetadata(record.sender);
      if (recordSender == null || !senderRule.allows(recordSender)) continue;
      final SmsEnvelope? sms = SmsEnvelope.fromOs(
        sender: recordSender,
        body: record.body,
        receivedAt: record.receivedAt,
        segments: record.segments,
        now: now,
      );
      if (sms == null) {
        invalid.add(PendingPatternReview(
          sourceRecordId: record.id,
          reason: 'invalid_retained_operator_sms',
        ));
        continue;
      }
      pending.add(PendingOperatorSms(sourceRecordId: record.id, sms: sms));
    }
    final PatternBacklogReanalysis reanalysis =
        const ApprovedOperatorPatternActivation().reanalyse(
      release: release,
      pending: pending,
      scope: scope,
    );

    return PatternReleaseReanalysed(
      PatternBacklogReanalysis(
        pushReady: reanalysis.pushReady,
        needsReview: <PendingPatternReview>[
          ...invalid,
          ...reanalysis.needsReview,
        ],
      ),
    );
  }
}

sealed class PatternReleaseDelivery {
  const PatternReleaseDelivery();
}

final class PatternReleaseRejected extends PatternReleaseDelivery {
  const PatternReleaseRejected(this.reason);
  final String reason;
}

final class PatternReleaseReanalysed extends PatternReleaseDelivery {
  const PatternReleaseReanalysed(this.result);
  final PatternBacklogReanalysis result;
}
