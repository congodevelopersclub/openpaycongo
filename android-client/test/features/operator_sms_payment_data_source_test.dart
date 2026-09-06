import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/approved_operator_pattern.dart';
import 'package:opencongopay/features/payment_inbox/domain/operator_sms_payment_data.dart';
import 'package:opencongopay/features/payment_inbox/infrastructure/operator_sms_payment_data_source.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';

void main() {
  const OutboxScope scope = OutboxScope(
    tenantId: 'tenant-001',
    deviceId: 'device-001',
  );

  test('joins guarded records to manual profiles without acknowledging the inbox',
      () async {
    final _Gateway gateway = _Gateway(
      records: <NativeSmsRecord>[
        NativeSmsRecord(
          id: 'a' * 43,
          sender: 'ORANGE',
          receivedAt: DateTime.utc(2026, 9, 6),
          segments: 1,
          body: 'Paid 12.50 USD ref REF-1234',
        ),
      ],
      profiles: const <NativeOperatorPaymentProfile>[
        NativeOperatorPaymentProfile(
          sender: 'ORANGE',
          provider: 'ORANGE_MONEY',
          structure: NativeOperatorPaymentStructure.manual,
          template: 'Paid {amount} {currency} ref {reference}',
        ),
      ],
    );

    final List<OperatorSmsPaymentData> results =
        await OperatorSmsPaymentDataSource(gateway: gateway).read(scope);

    expect(results.single, isA<PaymentDataReadyForPush>());
    expect(
      (results.single as PaymentDataReadyForPush).data.envelope.providerReference,
      'REF-1234',
    );
    expect(gateway.commitCalls, 0);
  });

  test('missing profiles remain reviewable and never become pushable', () async {
    final List<OperatorSmsPaymentData> results =
        await OperatorSmsPaymentDataSource(
          gateway: _Gateway(
            records: <NativeSmsRecord>[
              NativeSmsRecord(
                id: 'b' * 43,
                sender: 'ORANGE',
                receivedAt: DateTime.utc(2026, 9, 6),
                segments: 1,
                body: 'Unknown format',
              ),
            ],
          ),
        ).read(scope);

    expect(results.single, isA<PaymentDataNeedsReview>());
    expect(
      (results.single as PaymentDataNeedsReview).reason,
      'operator_payment_profile_missing',
    );
  });

  test('a verified release reanalyses retained records without acknowledging them',
      () async {
    final Ed25519 algorithm = Ed25519();
    final SimpleKeyPair pair = await algorithm.newKeyPair();
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    const String approvedAt = '2026-09-06T00:00:00Z';
    const String expiresAt = '2026-10-06T00:00:00Z';
    final Signature signature = await algorithm.sign(
      DeveloperApprovedOperatorPaymentPatternVerifier.canonicalPayload(
        schema: '1',
        provider: 'ORANGE_MONEY',
        sender: 'ORANGE',
        template: 'Paid {amount} {currency} ref {reference}',
        version: 1,
        approvedAt: approvedAt,
        expiresAt: expiresAt,
      ),
      keyPair: pair,
    );
    final _Gateway gateway = _Gateway(records: <NativeSmsRecord>[
      NativeSmsRecord(
        id: 'c' * 43,
        sender: 'ORANGE',
        receivedAt: DateTime.utc(2026, 9, 6),
        segments: 1,
        body: 'Paid 12.50 USD ref REF-1234',
      ),
    ]);

    final PatternReleaseDelivery result =
        await OperatorSmsPaymentDataSource(gateway: gateway).reanalyseRelease(
      encodedRelease: jsonEncode(<String, Object>{
        'schema_version': '1',
        'provider': 'ORANGE_MONEY',
        'sender': 'ORANGE',
        'template': 'Paid {amount} {currency} ref {reference}',
        'pattern_version': 1,
        'approved_at': approvedAt,
        'expires_at': expiresAt,
        'signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
      }),
      pinnedSigningKey: Uint8List.fromList(publicKey.bytes),
      now: DateTime.utc(2026, 9, 6, 0, 1),
      scope: scope,
    );

    expect(result, isA<PatternReleaseReanalysed>());
    expect(
      (result as PatternReleaseReanalysed).result.pushReady.single.sourceRecordId,
      'c' * 43,
    );
    expect(gateway.commitCalls, 0);
  });
}

final class _Gateway implements SmsGatewayPort {
  _Gateway({
    required this.records,
    this.profiles = const <NativeOperatorPaymentProfile>[],
  });

  final List<NativeSmsRecord> records;
  final List<NativeOperatorPaymentProfile> profiles;
  int commitCalls = 0;

  @override
  Future<List<NativeSmsRecord>> drainInbox() async => records;

  @override
  Future<List<NativeOperatorPaymentProfile>> listOperatorPaymentProfiles() async =>
      profiles;

  @override
  Future<void> commitInboxDecision(
    String id,
    NativeCaptureDecision decision,
  ) async {
    commitCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
