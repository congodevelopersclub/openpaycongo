import '../../payment_outbox/domain/payment_outbox.dart';
import '../../sms_gateway/domain/sms_gateway.dart';
import '../domain/operator_sms_payment_data.dart';
import '../domain/payment_ingestion.dart';
import 'operator_sms_payment_adapter.dart';
import 'platform_gemma4_proposal_port.dart';

/// The sole read boundary the separately-owned push worker needs. It joins the
/// authoritative encrypted inbox with its persisted operator profile, creates
/// immutable push-ready data when possible, and never acknowledges an SMS.
final class OperatorSmsPaymentDataSource {
  OperatorSmsPaymentDataSource({
    required SmsGatewayPort gateway,
    OperatorSmsPaymentAdapter adapter = const OperatorSmsPaymentAdapter(),
    Gemma4PaymentDataFactory? gemmaFactory,
  }) : _gateway = gateway,
       _adapter = adapter,
       _gemmaFactory = gemmaFactory;

  final SmsGatewayPort _gateway;
  final OperatorSmsPaymentAdapter _adapter;
  final Gemma4PaymentDataFactory? _gemmaFactory;

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
        await _gateway.listOperatorPaymentProfiles();
    final Map<String, NativeOperatorPaymentProfile> bySender =
        <String, NativeOperatorPaymentProfile>{};
    for (final NativeOperatorPaymentProfile profile in profiles) {
      if (bySender.putIfAbsent(profile.sender, () => profile) != null) {
        throw const FormatException('duplicate_operator_payment_profile');
      }
    }
    final List<NativeSmsRecord> records = await _gateway.drainInbox();
    final List<OperatorSmsPaymentData> data = <OperatorSmsPaymentData>[];
    for (final NativeSmsRecord record in records) {
      final NativeOperatorPaymentProfile? profile = bySender[record.sender];
      if (profile == null) {
        data.add(const PaymentDataNeedsReview('operator_payment_profile_missing'));
        continue;
      }
      if (profile.structure == NativeOperatorPaymentStructure.manual) {
        data.add(_adapter.interpret(record: record, profile: profile, scope: scope));
        continue;
      }
      final Gemma4PaymentDataFactory? gemmaFactory = _gemmaFactory;
      data.add(
        gemmaFactory == null
            ? const PaymentDataNeedsReview('gemma4_runtime_not_configured')
            : await _adapter.interpretWithGemma(
                record: record,
                profile: profile,
                scope: scope,
                factory: gemmaFactory,
              ),
      );
    }
    return List<OperatorSmsPaymentData>.unmodifiable(data);
  }
}
