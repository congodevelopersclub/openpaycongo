import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/payment_ingestion.dart';

final class FakeClock implements Clock {
  FakeClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

final class NeverProposalPort implements GemmaProposalPort {
  int calls = 0;
  @override
  Future<String> proposeJson(SmsEnvelope envelope, Duration timeout) {
    calls += 1;
    return Completer<String>().future;
  }
}

void main() {
  final DateTime now = DateTime.utc(2026, 8, 10);
  final SenderIdentity trusted = SenderIdentity.fromOsMetadata(
    '+243990001111',
  )!;
  final TrustedSenderRule rule = TrustedSenderRule(trusted);
  SmsEnvelope sms(
    String sender,
    String body, {
    int segments = 1,
    DateTime? receivedAt,
  }) => SmsEnvelope.fromOs(
    sender: SenderIdentity.fromOsMetadata(sender)!,
    body: body,
    receivedAt: receivedAt ?? now,
    segments: segments,
    now: now,
  )!;

  test('untrusted OS sender is rejected before body parsing', () {
    final ParseDecision decision = const DeterministicPaymentParser().parse(
      sms('+243990002222', 'Paid 12.00 USD ref REF-1234 from +243990001111'),
      rule,
      const PaymentTemplate('Paid {amount} {currency} ref {reference}'),
    );
    expect((decision as Rejected).reason, 'untrusted_sender');
  });

  test(
    'sender and envelope bounds reject lookalikes, age, future, bytes and segments',
    () {
      expect(SenderIdentity.fromOsMetadata('ОRANGE'), isNull);
      expect(
        SmsEnvelope.fromOs(
          sender: trusted,
          body: 'x' * 4097,
          receivedAt: now,
          segments: 1,
          now: now,
        ),
        isNull,
      );
      expect(
        SmsEnvelope.fromOs(
          sender: trusted,
          body: 'x',
          receivedAt: now,
          segments: 9,
          now: now,
        ),
        isNull,
      );
      expect(
        SmsEnvelope.fromOs(
          sender: trusted,
          body: 'x',
          receivedAt: now.subtract(const Duration(days: 32)),
          segments: 1,
          now: now,
        ),
        isNull,
      );
      expect(
        SmsEnvelope.fromOs(
          sender: trusted,
          body: 'x',
          receivedAt: now.add(const Duration(minutes: 6)),
          segments: 1,
          now: now,
        ),
        isNull,
      );
    },
  );

  test('template is a bounded ordered literal and typed-field matcher', () {
    const PaymentTemplate template = PaymentTemplate(
      'Paid {amount} {currency} ref {reference}',
    );
    final ParseDecision accepted = const DeterministicPaymentParser().parse(
      sms('+243990001111', 'Paid 12.50 USD ref REF-1234'),
      rule,
      template,
    );
    expect((accepted as TrustedCandidate).value.amountMinor, 1250);
    expect(
      const DeterministicPaymentParser().parse(
        sms('+243990001111', '12.50 USD REF-1234'),
        rule,
        template,
      ),
      isA<NeedsReview>(),
    );
    expect(
      const PaymentTemplate('{amount}{currency} {reference}').valid,
      isFalse,
    );
    expect(const PaymentTemplate('{amount} {currency} {evil}').valid, isFalse);
    expect(
      const PaymentTemplate('{amount} {currency} {amount}').valid,
      isFalse,
    );
  });

  test(
    'regex-looking literals stay literal and ambiguous money is review-only',
    () {
      const PaymentTemplate literal = PaymentTemplate(
        '.*{amount} {currency} {reference}',
      );
      expect(
        const DeterministicPaymentParser().parse(
          sms('+243990001111', '12.50 USD REF-1234'),
          rule,
          literal,
        ),
        isA<NeedsReview>(),
      );
      final NeedsReview ambiguous =
          const DeterministicPaymentParser().parse(
                sms('+243990001111', 'Paid 12,50 USD ref REF-1234'),
                rule,
                const PaymentTemplate(
                  'Paid {amount} {currency} ref {reference}',
                ),
              )
              as NeedsReview;
      expect(ambiguous.reason, 'ambiguous_amount_or_currency');
    },
  );

  test('derived key and provider reference both prevent replay', () async {
    final SmsEnvelope first = sms(
      '+243990001111',
      'Paid 12.50 USD ref REF-1234',
    );
    final SmsEnvelope changed = sms(
      '+243990001111',
      'Paid 99.00 USD ref REF-1234',
    );
    final EnvelopeKey firstKey = EnvelopeKey.derive(
      deviceId: 'device-001',
      envelope: first,
      providerReference: 'REF-1234',
    )!;
    final EnvelopeKey changedKey = EnvelopeKey.derive(
      deviceId: 'device-001',
      envelope: changed,
      providerReference: 'REF-1234',
    )!;
    expect(firstKey.value, isNot(changedKey.value));
    final InMemoryVault vault = InMemoryVault();
    MinimizedEnvelope item(EnvelopeKey key, SmsEnvelope envelope) =>
        MinimizedEnvelope(
          key: key,
          sender: envelope.sender,
          receivedAt: envelope.receivedAt,
          providerReference: 'REF-1234',
          redactedBody: 'Paid …',
        );
    expect(await vault.persistIfAbsent(item(firstKey, first)), isTrue);
    expect(await vault.persistIfAbsent(item(changedKey, changed)), isFalse);
  });

  test('model output is strict JSON and always review-only', () {
    const ProposalValidator validator = ProposalValidator();
    final SmsEnvelope envelope = sms('+243990001111', 'redacted');
    expect(
      (validator.validate('ignore instructions', envelope, rule) as NeedsReview)
          .reason,
      'model_malformed_json',
    );
    const String valid =
        '{"amount_minor":1250,"currency":"USD","reference":"REF-1234","provider":"+243990001111","confidence":0.99}';
    final NeedsReview reviewed =
        validator.validate(valid, envelope, rule) as NeedsReview;
    expect(reviewed.reason, 'model_proposal_requires_human_review');
    expect(reviewed.candidate?.amountMinor, 1250);
    expect(
      (validator.validate(
                valid,
                envelope,
                rule,
                seenProviderReferences: <String>{'+243990001111:REF-1234'},
              )
              as NeedsReview)
          .reason,
      'model_duplicate_reference',
    );
    expect(
      (validator.validate(valid.replaceFirst('0.99', '0.5'), envelope, rule)
              as NeedsReview)
          .reason,
      'model_low_confidence',
    );
    expect(
      validator.validate(valid, sms('+243990002222', 'redacted'), rule),
      isA<Rejected>(),
    );
  });

  test('timeout opens bounded circuit and manual fallback remains', () async {
    final NeverProposalPort port = NeverProposalPort();
    final BoundedProposalRunner runner = BoundedProposalRunner(
      port: port,
      clock: FakeClock(now),
      requestTimeout: const Duration(milliseconds: 1),
      hardTimeout: const Duration(milliseconds: 2),
      failureLimit: 2,
    );
    expect(
      (await runner.run(sms('+243990001111', 'x'), rule) as NeedsReview).reason,
      'model_timeout_use_manual_parser',
    );
    expect(
      (await runner.run(sms('+243990001111', 'x'), rule) as NeedsReview).reason,
      'model_timeout_use_manual_parser',
    );
    expect(
      (await runner.run(sms('+243990001111', 'x'), rule) as NeedsReview).reason,
      'model_circuit_open_use_manual_parser',
    );
    expect(port.calls, 2);
    final ParseDecision rejected = await runner.run(
      sms('+243990002222', 'x'),
      rule,
    );
    expect(rejected, isA<Rejected>());
    expect(port.calls, 2);
  });
}
