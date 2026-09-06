import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/operator_sms_payment_data.dart';
import 'package:opencongopay/features/payment_inbox/domain/payment_ingestion.dart';
import 'package:opencongopay/features/payment_inbox/infrastructure/operator_sms_payment_adapter.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';

void main() {
  final DateTime receivedAt = DateTime.utc(2026, 9, 6, 12);
  final SenderIdentity orange = SenderIdentity.fromOsMetadata('ORANGE')!;
  final OutboxScope scope = OutboxScope(
    tenantId: 'tenant-001',
    deviceId: 'device-001',
  );
  final OperatorSmsPaymentProfile profile = OperatorSmsPaymentProfile(
    provider: 'ORANGE_MONEY',
    senderRule: TrustedSenderRule(orange),
    structure: const ManualPaymentStructure(PaymentTemplate(
      'Paid {amount} {currency} ref {reference}',
    )),
  );
  SmsEnvelope sms(String body, {SenderIdentity? sender}) => SmsEnvelope.fromOs(
    sender: sender ?? orange,
    body: body,
    receivedAt: receivedAt,
    segments: 1,
    now: receivedAt,
  )!;

  test('trusted operator SMS becomes immutable data ready for the push worker', () {
    final OperatorSmsPaymentData result = const OperatorSmsPaymentDataFactory()
        .interpret(
          sourceRecordId: 'a' * 43,
          sms: sms('Paid 12.50 USD ref REF-1234'),
          profile: profile,
          scope: scope,
        );

    expect(result, isA<PaymentDataReadyForPush>());
    final CapturedPaymentForPush data = (result as PaymentDataReadyForPush).data;
    expect(data.sourceRecordId, 'a' * 43);
    expect(data.envelope.provider, 'ORANGE_MONEY');
    expect(data.envelope.providerReference, 'REF-1234');
    expect(data.envelope.amountMinor, 1250);
    expect(data.envelope.currency, 'USD');
    expect(data.envelope.capturedAt, receivedAt);
    expect(data.envelope.scope, scope);
  });

  test('unrecognized SMS never becomes pushable payment data', () {
    final OperatorSmsPaymentData result = const OperatorSmsPaymentDataFactory()
        .interpret(
          sourceRecordId: 'b' * 43,
          sms: sms('Credit received: 12.50 USD'),
          profile: profile,
          scope: scope,
        );

    expect(result, isA<PaymentDataNeedsReview>());
    expect((result as PaymentDataNeedsReview).reason, 'template_literal_mismatch');
  });

  test('profile provider is explicit and never inferred from a sender phone number', () {
    final SenderIdentity phone = SenderIdentity.fromOsMetadata('+243990001111')!;
    final OperatorSmsPaymentProfile phoneProfile = OperatorSmsPaymentProfile(
      provider: 'AIRTEL_MONEY',
      senderRule: TrustedSenderRule(phone),
      structure: const ManualPaymentStructure(
        PaymentTemplate('Paid {amount} {currency} ref {reference}'),
      ),
    );

    final OperatorSmsPaymentData result = const OperatorSmsPaymentDataFactory()
        .interpret(
          sourceRecordId: 'c' * 43,
          sms: sms('Paid 12.50 USD ref REF-1234', sender: phone),
          profile: phoneProfile,
          scope: scope,
        );

    expect(
      (result as PaymentDataReadyForPush).data.envelope.provider,
      'AIRTEL_MONEY',
    );
  });

  test('Gemma 4 proposal stays review-gated before it becomes pushable', () async {
    final OperatorSmsPaymentProfile gemmaProfile = OperatorSmsPaymentProfile(
      provider: 'ORANGE_MONEY',
      senderRule: TrustedSenderRule(orange),
      structure: const Gemma4AssistedPaymentStructure(),
    );
    final Gemma4PaymentDataFactory factory = Gemma4PaymentDataFactory(
      BoundedProposalRunner(
        port: _GemmaPort(
          '{"amount_minor":1250,"currency":"USD","reference":"REF-1234","provider":"ORANGE","confidence":0.99}',
        ),
        clock: _FixedClock(receivedAt),
      ),
    );

    final OperatorSmsPaymentData proposal = await factory.propose(
      sourceRecordId: 'd' * 43,
      sms: sms('Provider changed this notification format'),
      profile: gemmaProfile,
      scope: scope,
    );
    expect(proposal, isA<PaymentDataNeedsReview>());
    expect((proposal as PaymentDataNeedsReview).proposal, isNotNull);

    final OperatorSmsPaymentData accepted = factory.confirm(
      proposal.proposal!,
      confirmedByUser: true,
    );
    expect(accepted, isA<PaymentDataReadyForPush>());
    expect(
      (accepted as PaymentDataReadyForPush).data.envelope.provider,
      'ORANGE_MONEY',
    );
  });

  test('guarded native inbox and profile records become pushable data together', () {
    final OperatorSmsPaymentData result = OperatorSmsPaymentAdapter(
      now: () => receivedAt,
    ).interpret(
      record: NativeSmsRecord(
        id: 'e' * 43,
        sender: 'ORANGE',
        receivedAt: receivedAt,
        segments: 1,
        body: 'Paid 12.50 USD ref REF-1234',
      ),
      profile: const NativeOperatorPaymentProfile(
        sender: 'ORANGE',
        provider: 'ORANGE_MONEY',
        structure: NativeOperatorPaymentStructure.manual,
        template: 'Paid {amount} {currency} ref {reference}',
      ),
      scope: scope,
    );

    expect(result, isA<PaymentDataReadyForPush>());
    expect(
      (result as PaymentDataReadyForPush).data.envelope.providerReference,
      'REF-1234',
    );
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.now);
  final DateTime now;
  @override
  DateTime nowUtc() => now;
}

final class _GemmaPort implements GemmaProposalPort {
  const _GemmaPort(this.response);
  final String response;
  @override
  Future<String> proposeJson(SmsEnvelope envelope, Duration timeout) async => response;
}
