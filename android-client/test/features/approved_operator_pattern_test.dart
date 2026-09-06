import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/approved_operator_pattern.dart';
import 'package:opencongopay/features/payment_inbox/domain/operator_sms_payment_data.dart';
import 'package:opencongopay/features/payment_inbox/domain/payment_ingestion.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';

const String _provider = 'ORANGE_MONEY';
const String _sender = 'ORANGE';
const String _template = 'Paid {amount} {currency} ref {reference}';

void main() {
  const OutboxScope scope = OutboxScope(
    tenantId: 'tenant-001',
    deviceId: 'device-001',
  );
  const String provider = 'ORANGE_MONEY';
  const String sender = 'ORANGE';
  const String template = 'Paid {amount} {currency} ref {reference}';
  final DateTime now = DateTime.utc(2026, 9, 6, 0, 2);

  test('an unsigned Gemma candidate never becomes an approved release', () async {
    final Ed25519 algorithm = Ed25519();
    final SimpleKeyPair pair = await algorithm.newKeyPair();
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    const String approvedAt = '2026-09-06T00:00:00Z';
    const String expiresAt = '2026-10-06T00:00:00Z';
    final Signature signed = await algorithm.sign(
      DeveloperApprovedOperatorPaymentPatternVerifier.canonicalPayload(
        schema: '1',
        provider: provider,
        sender: sender,
        template: template,
        version: 1,
        approvedAt: approvedAt,
        expiresAt: expiresAt,
      ),
      keyPair: pair,
    );
    final Uint8List alteredSignature = Uint8List.fromList(signed.bytes);
    alteredSignature[0] ^= 1;

    final DeveloperApprovedOperatorPaymentPattern? release =
        await const DeveloperApprovedOperatorPaymentPatternVerifier().verify(
          encodedRelease: jsonEncode(<String, Object>{
            'schema_version': '1',
            'provider': provider,
            'sender': sender,
            'template': template,
            'pattern_version': 1,
            'approved_at': approvedAt,
            'expires_at': expiresAt,
            'signature': base64UrlEncode(alteredSignature).replaceAll('=', ''),
          }),
          pinnedSigningKey: Uint8List.fromList(publicKey.bytes),
          now: now,
        );

    expect(release, isNull);
  });

  test('an expired signed release never becomes an approved release', () async {
    final Ed25519 algorithm = Ed25519();
    final SimpleKeyPair pair = await algorithm.newKeyPair();
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    const String approvedAt = '2026-08-01T00:00:00Z';
    const String expiresAt = '2026-09-01T00:00:00Z';
    final Signature signature = await algorithm.sign(
      DeveloperApprovedOperatorPaymentPatternVerifier.canonicalPayload(
        schema: '1',
        provider: provider,
        sender: sender,
        template: template,
        version: 1,
        approvedAt: approvedAt,
        expiresAt: expiresAt,
      ),
      keyPair: pair,
    );

    final DeveloperApprovedOperatorPaymentPattern? release =
        await const DeveloperApprovedOperatorPaymentPatternVerifier().verify(
          encodedRelease: jsonEncode(<String, Object>{
            'schema_version': '1',
            'provider': provider,
            'sender': sender,
            'template': template,
            'pattern_version': 1,
            'approved_at': approvedAt,
            'expires_at': expiresAt,
            'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
          }),
          pinnedSigningKey: Uint8List.fromList(publicKey.bytes),
          now: now,
        );

    expect(release, isNull);
  });

  test('a verified developer release reanalyses every retained matching SMS',
      () async {
    final DeveloperApprovedOperatorPaymentPattern release =
        await _verifiedRelease(now);
    final List<PendingOperatorSms> pending = <PendingOperatorSms>[
      PendingOperatorSms(
        sourceRecordId: 'b' * 43,
        sms: _sms('Paid 12.50 USD ref REF-1234', now),
      ),
      PendingOperatorSms(
        sourceRecordId: 'c' * 43,
        sms: _sms('Paid 5 CDF ref REF-5678', now),
      ),
    ];

    final PatternBacklogReanalysis result =
        const ApprovedOperatorPatternActivation().reanalyse(
          release: release,
          pending: pending,
          scope: scope,
        );

    expect(
      result.pushReady.map((CapturedPaymentForPush data) => data.sourceRecordId),
      <String>['b' * 43, 'c' * 43],
    );
    expect(
      result.pushReady
          .map((CapturedPaymentForPush data) => data.provenance.kind)
          .toSet(),
      <PaymentParserKind>{PaymentParserKind.developerApprovedPattern},
    );
    expect(
      result.pushReady
          .map((CapturedPaymentForPush data) => data.provenance.approvedPatternVersion)
          .toSet(),
      <int?>{1},
    );
    expect(result.needsReview, isEmpty);
  });

  test('a verified release never reanalyses another sender or duplicate record',
      () async {
    final DeveloperApprovedOperatorPaymentPattern release =
        await _verifiedRelease(now);
    final PatternBacklogReanalysis result =
        const ApprovedOperatorPatternActivation().reanalyse(
          release: release,
          pending: <PendingOperatorSms>[
            PendingOperatorSms(
              sourceRecordId: 'd' * 43,
              sms: _sms('Paid 1 CDF ref REF-1', now),
            ),
            PendingOperatorSms(
              sourceRecordId: 'd' * 43,
              sms: _sms('Paid 2 CDF ref REF-2', now),
            ),
            PendingOperatorSms(
              sourceRecordId: 'e' * 43,
              sms: SmsEnvelope.fromOs(
                sender: SenderIdentity.fromOsMetadata('AIRTEL')!,
                body: 'Paid 3 CDF ref REF-3',
                receivedAt: now,
                segments: 1,
                now: now,
              )!,
            ),
          ],
          scope: scope,
        );

    expect(result.pushReady.single.sourceRecordId, 'd' * 43);
    expect(result.needsReview, isEmpty);
  });
}

SmsEnvelope _sms(String body, DateTime now) {
  return SmsEnvelope.fromOs(
    sender: SenderIdentity.fromOsMetadata(_sender)!,
    body: body,
    receivedAt: now,
    segments: 1,
    now: now,
  )!;
}

Future<DeveloperApprovedOperatorPaymentPattern> _verifiedRelease(
  DateTime now,
) async {
  final Ed25519 algorithm = Ed25519();
  final SimpleKeyPair pair = await algorithm.newKeyPair();
  final SimplePublicKey publicKey = await pair.extractPublicKey();
  const String approvedAt = '2026-09-06T00:00:00Z';
  const String expiresAt = '2026-10-06T00:00:00Z';
  final Signature signature = await algorithm.sign(
    DeveloperApprovedOperatorPaymentPatternVerifier.canonicalPayload(
      schema: '1',
      provider: _provider,
      sender: _sender,
      template: _template,
      version: 1,
      approvedAt: approvedAt,
      expiresAt: expiresAt,
    ),
    keyPair: pair,
  );
  final DeveloperApprovedOperatorPaymentPattern? release =
      await const DeveloperApprovedOperatorPaymentPatternVerifier().verify(
        encodedRelease: jsonEncode(<String, Object>{
          'schema_version': '1',
          'provider': _provider,
          'sender': _sender,
          'template': _template,
          'pattern_version': 1,
          'approved_at': approvedAt,
          'expires_at': expiresAt,
          'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
        }),
        pinnedSigningKey: Uint8List.fromList(publicKey.bytes),
        now: now,
      );

  expect(release, isNotNull);
  return release!;
}
