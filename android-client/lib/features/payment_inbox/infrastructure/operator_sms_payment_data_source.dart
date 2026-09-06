import 'dart:typed_data';

import '../../payment_outbox/domain/payment_outbox.dart';
import '../../sms_gateway/domain/sms_gateway.dart';
import '../domain/approved_operator_pattern.dart';
import '../domain/operator_sms_payment_data.dart';
import '../domain/payment_ingestion.dart';
import 'operator_sms_payment_adapter.dart';
import 'platform_gemma4_proposal_port.dart';

/// The sole read boundary the separately-owned push worker needs. It joins the
/// authoritative encrypted inbox with its persisted operator profile, creates
/// immutable push-ready data when possible, and never acknowledges an SMS.
final class OperatorSmsPaymentDataSource {
  OperatorSmsPaymentDataSource({
    required this.gateway,
    this.adapter = const OperatorSmsPaymentAdapter(),
    this.gemmaFactory,
  });

  final SmsGatewayPort gateway;
  final OperatorSmsPaymentAdapter adapter;
  final Gemma4PaymentDataFactory? gemmaFactory;

  /// Production composition for Android: Gemma stays completely on-device.
  factory OperatorSmsPaymentDataSource.onDeviceGemma({
    required SmsGatewayPort gateway,
    OperatorSmsPaymentAdapter adapter = const OperatorSmsPaymentAdapter(),
  }) => OperatorSmsPaymentDataSource(
    gateway: gateway,
    adapter: adapter,
    gemmaFactory: Gemma4PaymentDataFactory(
      BoundedProposalRunner(
        port: const PlatformGemma4ProposalPort(),
        clock: const SystemClock(),
      ),
    ),
  );

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
      if (profile.structure == NativeOperatorPaymentStructure.manual) {
        data.add(adapter.interpret(record: record, profile: profile, scope: scope));
        continue;
      }
      final Gemma4PaymentDataFactory? configuredGemmaFactory = gemmaFactory;
      data.add(
        configuredGemmaFactory == null
            ? const PaymentDataNeedsReview('gemma4_runtime_not_configured')
            : await adapter.interpretWithGemma(
                record: record,
                profile: profile,
                scope: scope,
                factory: configuredGemmaFactory,
              ),
      );
    }
    return List<OperatorSmsPaymentData>.unmodifiable(data);
  }

  /// Installs no state and does not acknowledge an SMS. The independently-owned
  /// release delivery worker calls this with one backend-published release; only
  /// the verifier can obtain the authority type accepted by reanalysis.
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
