import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/domain/signed_sms_deposit_parser.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';

final DateTime _now = DateTime.utc(2026, 9, 10, 10);
final DateTime _receivedAt = DateTime.utc(2026, 9, 5, 10);
const String _testSigningPublicKey =
    'iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w';
const String _knownGoodTemplate =
    'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}';
const String _knownGoodBody =
    'Received 125.50 CDF; ref SAMPLE-1234; customer test-account-001; at 2026-09-05T09:00:00Z';

final class _SignedCandidate {
  const _SignedCandidate({required this.bundle, required this.verifier});

  final String bundle;
  final SignedSmsDepositReleaseVerifier verifier;
}

Future<_SignedCandidate> _signedCandidate({
  required String sender,
  required String provider,
  required String template,
}) async {
  // Disposable fixture authority only; it never represents a production rule.
  final SimpleKeyPair key = await Ed25519().newKeyPairFromSeed(
    List<int>.filled(32, 1),
  );
  final SimplePublicKey public = await key.extractPublicKey();
  expect(
    base64UrlEncode(public.bytes).replaceAll('=', ''),
    _testSigningPublicKey,
  );
  final Map<String, dynamic> release = <String, dynamic>{
    'schema_version': '1',
    'provider': provider,
    'sender': sender,
    'template': template,
    'pattern_version': 1,
    'approved_at': '2026-08-01T00:00:00Z',
    'expires_at': '2026-10-01T00:00:00Z',
  };
  final Signature signature = await Ed25519().sign(
    SignedSmsDepositReleaseVerifier.canonicalPayload(release),
    keyPair: key,
  );
  release['signature'] = base64UrlEncode(signature.bytes).replaceAll('=', '');
  return _SignedCandidate(
    bundle: jsonEncode(release),
    verifier: SignedSmsDepositReleaseVerifier(
      pinnedSigningPublicKey: base64UrlEncode(public.bytes).replaceAll('=', ''),
    ),
  );
}

List<Map<String, dynamic>> _loadFixtures() {
  final Map<String, dynamic> dataset =
      jsonDecode(
            File(
              'test/features/fixtures/sanitized_sms_parser_samples.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  return (dataset['fixtures'] as List<Object?>).cast<Map<String, dynamic>>();
}

String _replaceFirstWithField(String body, Object? rawValue, String field) {
  if (rawValue is! String || rawValue.isEmpty) return body;
  final int index = body.indexOf(rawValue);
  if (index < 0) return body;
  return '${body.substring(0, index)}{$field}${body.substring(index + rawValue.length)}';
}

bool _isPartialIdentifier(String value) =>
    value.toLowerCase().contains('partial') ||
    value.toLowerCase().contains('obscured') ||
    value.toLowerCase().contains('partly');

/// Builds only from fields that are explicitly visible in the sanitized body.
/// A visible counterparty phone is not mapped to the opaque backend key unless an explicit convention says to do so.
String _candidateTemplate(Map<String, dynamic> fixture) {
  String template = fixture['sanitized_transcription'] as String;
  final Map<String, dynamic> expected =
      fixture['expected'] as Map<String, dynamic>;
  final Object? transactionAmount = expected['transaction_amount'];
  if (transactionAmount is Map<String, dynamic>) {
    template = _replaceFirstWithField(
      template,
      transactionAmount['raw'],
      'amount',
    );
    template = _replaceFirstWithField(
      template,
      transactionAmount['currency'],
      'currency',
    );
  }
  final String? reference =
      (expected['reference'] ?? expected['transaction_id']) as String?;
  if (reference != null && !_isPartialIdentifier(reference)) {
    template = _replaceFirstWithField(template, reference, 'reference');
  }
  template = _replaceFirstWithField(
    template,
    expected['transaction_datetime_raw'],
    'occurred_at',
  );
  return template;
}

Set<String> _visibleTemplateFields(String template) => RegExp(
  r'\{([a-z_]+)\}',
).allMatches(template).map((RegExpMatch match) => match.group(1)!).toSet();

String _testSender(Map<String, dynamic> fixture) =>
    fixture['sender_alias'] as String;

List<String> _observedParserGaps(Map<String, dynamic> fixture) {
  final Map<String, dynamic> expected =
      fixture['expected'] as Map<String, dynamic>;
  final List<String> gaps = <String>[];
  if (fixture['customer_mapping_status'] == 'unspecified') {
    gaps.add('customer_mapping_unspecified');
  }
  final Object? amountValue = expected['transaction_amount'];
  if (amountValue is Map<String, dynamic>) {
    final String rawAmount = amountValue['raw'] as String;
    final String currency = amountValue['currency'] as String;
    if (!RegExp(r'^[0-9]{1,12}(?:\.[0-9]{1,2})?$').hasMatch(rawAmount)) {
      gaps.add('unsupported_amount_format');
    }
    if (currency != 'CDF') gaps.add('unsupported_currency');
  }
  final String? occurredAt = expected['transaction_datetime_raw'] as String?;
  if (occurredAt == null) {
    gaps.add('missing_body_event_time');
  } else if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$',
  ).hasMatch(occurredAt)) {
    gaps.add('unsupported_event_time_format');
  }
  return gaps;
}

String _candidateStatus(Map<String, dynamic> fixture) {
  final String classification = fixture['classification'] as String;
  return '$classification candidate template incomplete: '
      '${_observedParserGaps(fixture).join(', ')}';
}

String _testProvider(String sender) =>
    sender == 'MPESA' ? 'TEST_MOBILE_MONEY' : 'TEST_WALLET_ALERT';

final class _GrammarProbe {
  const _GrammarProbe({
    required this.name,
    required this.amount,
    required this.currency,
    required this.occurredAt,
    required this.shouldParse,
    this.expectedAmountMinor,
  });

  final String name;
  final String amount;
  final String currency;
  final String occurredAt;
  final bool shouldParse;
  final int? expectedAmountMinor;
}

Future<ProviderDeposit?> _parseGrammarProbe(_GrammarProbe probe) async {
  // These values are test-only fillers for fields missing from screenshots.
  // They isolate parser grammar; they are never written into sample fixtures
  // or treated as a real customer/account mapping or event timestamp.
  final _SignedCandidate signed = await _signedCandidate(
    sender: 'TESTPROBE',
    provider: 'TEST_PROBE',
    template: _knownGoodTemplate,
  );
  final SignedSmsDepositRelease release = (await signed.verifier.verify(
    signed.bundle,
    _now,
  ))!;
  final String body =
      'Received ${probe.amount} ${probe.currency}; ref PROBE-REF-01; '
      'customer TEST_ONLY_CUSTOMER; at ${probe.occurredAt}';
  return const SignedSmsDepositParser().parse(
    NativeSmsRecord(
      id: _testId(1),
      sender: 'TESTPROBE',
      receivedAt: _receivedAt,
      segments: 1,
      body: body,
    ),
    release,
    _now,
  );
}

String _testId(int index) => List<String>.filled(
  43,
  'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[index],
).join();

void _expectVisibleField(Map<String, dynamic> expected, String body) {
  final Object? amount = expected['transaction_amount'];
  if (amount is Map<String, dynamic>) {
    expect(body, contains(amount['raw'] as String));
    expect(body, contains(amount['currency'] as String));
  }
  final String? reference =
      (expected['reference'] ?? expected['transaction_id']) as String?;
  if (reference != null) {
    if (_isPartialIdentifier(reference)) {
      final RegExpMatch? tid = RegExp(
        r'\[TID_[A-Z0-9_]+',
      ).firstMatch(reference);
      if (tid != null) expect(body, contains(tid.group(0)!));
    } else {
      expect(body, contains(reference));
    }
  }
  final String? occurredAt = expected['transaction_datetime_raw'] as String?;
  if (occurredAt != null) expect(body, contains(occurredAt));
  for (final String key in <String>[
    'ending_balance',
    'fee',
    'discount_or_remise',
    'stated_plan_price',
    'stated_charge',
  ]) {
    final Object? amount = expected[key];
    if (amount is Map<String, dynamic>) {
      final String raw = amount['raw'] as String;
      final String currency = amount['currency'] as String;
      expect(body, contains(raw));
      if (key == 'stated_plan_price' && currency == 'USD') {
        expect(
          raw.startsWith(r'$'),
          isTrue,
          reason: 'The SMS marks this USD price with the dollar symbol',
        );
      } else {
        expect(body, contains(currency));
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final List<Map<String, dynamic>> fixtures = _loadFixtures();
  final List<Map<String, dynamic>> smsFixtures = fixtures
      .where(
        (Map<String, dynamic> fixture) =>
            fixture['classification'] != 'duplicate_capture',
      )
      .toList();

  // The screenshot bodies are not passed to parse(): no valid candidate rule
  // exists until a customer-key mapping convention and signed operator
  // template are supplied. These are schema/fixture checks, not recognition.
  group('sanitized sample metadata and candidate-template completeness', () {
    for (final Map<String, dynamic> fixture in smsFixtures) {
      final String fixtureId = fixture['fixture_id'] as String;
      final String classification = fixture['classification'] as String;
      final String visibility = fixture['visibility'] as String;
      final String direction = fixture['transaction_direction'] as String;
      final String sender = _testSender(fixture);
      final Map<String, dynamic> expected =
          fixture['expected'] as Map<String, dynamic>;
      final String body = fixture['sanitized_transcription'] as String;
      final String candidateValue = _candidateTemplate(fixture);
      final DepositSmsTemplate candidateTemplate = DepositSmsTemplate(
        candidateValue,
      );
      final Set<String> candidateFields = _visibleTemplateFields(
        candidateValue,
      );
      final Set<String> missingFields = DepositSmsTemplate.fields.difference(
        candidateFields,
      );

      test('${_candidateStatus(fixture)}: $fixtureId', () async {
        expect(fixture['sms_transport_direction'], 'incoming_sms');
        expect(RegExp(r'^[A-Z0-9]{3,11}$').hasMatch(sender), isTrue);
        _expectVisibleField(expected, body);

        // The backend key is opaque. No convention says whether a visible payer,
        // recipient, or handset identifier maps to it, so no value is assigned.
        // A payer phone could be used only after an explicit normalization rule.
        expect(fixture['customer_mapping_status'], 'unspecified');
        expect(missingFields, contains('customer'));
        if (expected['transaction_datetime_raw'] == null) {
          expect(missingFields, contains('occurred_at'));
        } else {
          expect(missingFields, isNot(contains('occurred_at')));
        }
        if (expected['transaction_amount'] == null) {
          expect(candidateFields, isNot(contains('amount')));
          expect(candidateFields, isNot(contains('currency')));
        }
        expect(
          candidateTemplate.valid,
          isFalse,
          reason: 'No valid signed candidate can be built from visible fields',
        );

        final _SignedCandidate signed = await _signedCandidate(
          sender: sender,
          provider: _testProvider(sender),
          template: candidateValue,
        );
        expect(
          await signed.verifier.verify(signed.bundle, _now),
          isNull,
          reason: 'A test signature cannot make an incomplete template valid',
        );

        if (direction == 'incoming' && visibility == 'full') {
          expect(classification, startsWith('incoming_'));
          // This is an observed inflow, but no signed operator template or
          // customer-key mapping convention is supplied by the sample set.
          expect(missingFields, contains('customer'));
          final List<String> gaps = _observedParserGaps(fixture);
          expect(gaps, contains('customer_mapping_unspecified'));
          if (expected['transaction_datetime_raw'] == null) {
            expect(gaps, contains('missing_body_event_time'));
          } else {
            expect(gaps, contains('unsupported_event_time_format'));
          }
          final Object? amountValue = expected['transaction_amount'];
          if (classification == 'incoming_credit_cross_currency') {
            expect((amountValue as Map<String, dynamic>)['currency'], 'CDF');
            expect(
              (expected['fee'] as Map<String, dynamic>)['currency'],
              'USD',
            );
            expect(
              (expected['ending_balance'] as Map<String, dynamic>)['currency'],
              'USD',
            );
          }
          if (amountValue is Map<String, dynamic>) {
            final String rawAmount = amountValue['raw'] as String;
            final String currency = amountValue['currency'] as String;
            if (!RegExp(
              r'^[0-9]{1,12}(?:\.[0-9]{1,2})?$',
            ).hasMatch(rawAmount)) {
              expect(gaps, contains('unsupported_amount_format'));
            }
            if (currency != 'CDF') {
              expect(gaps, contains('unsupported_currency'));
            }
          }
        } else if (direction == 'outgoing' &&
            visibility == 'full' &&
            !classification.startsWith('partial_')) {
          expect(
            classification,
            anyOf(startsWith('outgoing_'), equals('cash_withdrawal')),
          );
          expect(
            candidateTemplate.valid,
            isFalse,
            reason:
                'No customer-key mapping convention is specified in this fixture',
          );
        } else {
          expect(
            visibility == 'partial' ||
                classification.startsWith('partial_') ||
                direction == 'unknown' ||
                direction == 'not_applicable' ||
                classification == 'balance_inquiry',
            isTrue,
            reason: 'Unknown or non-transaction evidence is kept separate',
          );
          expect(candidateTemplate.valid, isFalse);
        }
      });
    }
  });

  group('sanitized SMS bodies versus a valid canonical test control', () {
    late final Map<String, SignedSmsDepositRelease> controlReleases;

    setUpAll(() async {
      controlReleases = <String, SignedSmsDepositRelease>{};
      for (final String sender in <String>{'MPESA', 'SHORTCODE01'}) {
        final _SignedCandidate signed = await _signedCandidate(
          sender: sender,
          provider: _testProvider(sender),
          template: _knownGoodTemplate,
        );
        controlReleases[sender] = (await signed.verifier.verify(
          signed.bundle,
          _now,
        ))!;
      }
    });

    // A valid generic control proves only that these literal bodies do not
    // match this test template. It is not an operator rule or a coverage claim.
    for (final MapEntry<int, Map<String, dynamic>> entry
        in smsFixtures.asMap().entries) {
      final Map<String, dynamic> fixture = entry.value;
      final String fixtureId = fixture['fixture_id'] as String;
      final String sender = _testSender(fixture);
      test('$fixtureId is a known-control-template nonmatch', () {
        final SignedSmsDepositRelease release = controlReleases[sender]!;
        final SignedSmsDepositParser parser = const SignedSmsDepositParser();
        final NativeSmsRecord controlRecord = NativeSmsRecord(
          id: _testId(entry.key),
          sender: sender,
          receivedAt: _receivedAt,
          segments: 1,
          body: _knownGoodBody,
        );
        final ProviderDeposit? control = parser.parse(
          controlRecord,
          release,
          _now,
        );
        expect(
          control,
          isNotNull,
          reason:
              'Same signed template, sender, and receipt metadata must parse the control',
        );
        expect(control!.amountMinor, 12550);
        expect(control.currency, 'CDF');
        expect(control.providerReference, 'SAMPLE-1234');
        expect(control.customerLookupIdentifier, 'test-account-001');
        expect(control.providerOccurredAt, '2026-09-05T09:00:00Z');

        final ProviderDeposit? sample = parser.parse(
          NativeSmsRecord(
            id: _testId(entry.key),
            sender: sender,
            receivedAt: _receivedAt,
            segments: 1,
            body: fixture['sanitized_transcription'] as String,
          ),
          release,
          _now,
        );
        expect(
          sample,
          isNull,
          reason: 'This only shows a nonmatch to the canonical test template',
        );
      });
    }
  });

  test('image 07 is a duplicate capture, not a new SMS transaction', () {
    final Map<String, dynamic> duplicate = fixtures.singleWhere(
      (Map<String, dynamic> fixture) =>
          fixture['classification'] == 'duplicate_capture',
    );
    expect(duplicate['expected']['duplicate_of'], 'image_01');
    final Set<String> fixtureIds = smsFixtures
        .map((Map<String, dynamic> fixture) => fixture['fixture_id'] as String)
        .toSet();
    expect(fixtureIds, hasLength(smsFixtures.length));
    expect(
      smsFixtures.where(
        (Map<String, dynamic> fixture) =>
            (fixture['source_images'] as List<Object?>).contains('image_07'),
      ),
      isNotEmpty,
      reason: 'Overlapping bubbles are represented once with all source images',
    );
  });

  test('fixture counts separate inflows, outflows, and ambiguous evidence', () {
    final List<Map<String, dynamic>> inflows = smsFixtures
        .where(
          (Map<String, dynamic> fixture) =>
              fixture['transaction_direction'] == 'incoming' &&
              fixture['visibility'] == 'full' &&
              (fixture['classification'] as String).startsWith('incoming_'),
        )
        .toList();
    final List<Map<String, dynamic>> outflowsAndBalances = smsFixtures
        .where(
          (Map<String, dynamic> fixture) =>
              (fixture['transaction_direction'] == 'outgoing' &&
                  fixture['visibility'] == 'full' &&
                  !(fixture['classification'] as String).startsWith(
                    'partial_',
                  )) ||
              fixture['classification'] == 'balance_inquiry',
        )
        .toList();
    final List<Map<String, dynamic>> ambiguousEvidence = smsFixtures
        .where(
          (Map<String, dynamic> fixture) =>
              fixture['visibility'] == 'partial' ||
              (fixture['classification'] as String).startsWith('partial_') ||
              fixture['transaction_direction'] == 'unknown',
        )
        .toList();

    expect(smsFixtures, hasLength(35));
    expect(inflows, hasLength(7));
    expect(outflowsAndBalances, hasLength(21));
    expect(ambiguousEvidence, hasLength(7));
    expect(
      inflows.every(
        (Map<String, dynamic> fixture) =>
            fixture['customer_mapping_status'] == 'unspecified',
      ),
      isTrue,
      reason:
          'No customer-key mapping convention is specified for these inflow fixtures',
    );
  });

  // Each probe reuses a complete canonical signed control and changes one
  // observed field while other required fields use test-only fillers. These
  // are grammar diagnostics, not parses of the screenshot SMS.
  group('synthetic grammar diagnostics for observed value formats', () {
    const String validTestTime = '2026-09-05T09:00:00Z';
    const List<_GrammarProbe> probes = <_GrammarProbe>[
      _GrammarProbe(
        name: 'sample_08_23_amount_4_000',
        amount: '4.000',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'sample_08_27_amount_5_000',
        amount: '5.000',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'sample_08_28_amount_2_000',
        amount: '2.000',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'wallet amount with four fractional digits',
        amount: '50.0000',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'wallet amount with four fractional digits, second sample',
        amount: '80.0000',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'sample_local_currency_label_Fc',
        amount: '4.00',
        currency: 'Fc',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'wallet USD currency',
        amount: '50.00',
        currency: 'USD',
        occurredAt: validTestTime,
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'sample_DMY_event_time',
        amount: '4.00',
        currency: 'CDF',
        occurredAt: '23-08-2026 a 19:10:01',
        shouldParse: false,
      ),
      _GrammarProbe(
        name: 'one-decimal CDF amount accepted by grammar',
        amount: '11350.0',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: true,
        expectedAmountMinor: 1135000,
      ),
      _GrammarProbe(
        name: 'one-decimal CDF amount, second sample',
        amount: '34050.0',
        currency: 'CDF',
        occurredAt: validTestTime,
        shouldParse: true,
        expectedAmountMinor: 3405000,
      ),
    ];

    for (final _GrammarProbe probe in probes) {
      test('synthetic diagnostic: ${probe.name}', () async {
        final ProviderDeposit? deposit = await _parseGrammarProbe(probe);
        if (!probe.shouldParse) {
          expect(deposit, isNull);
          return;
        }
        expect(deposit, isNotNull);
        expect(deposit!.amountMinor, probe.expectedAmountMinor);
        expect(deposit.currency, 'CDF');
        expect(deposit.customerLookupIdentifier, 'TEST_ONLY_CUSTOMER');
        expect(deposit.providerOccurredAt, probe.occurredAt);
      });
    }
  });

  test(
    'supported signed CDF control still yields the complete deposit entity',
    () async {
      final _SignedCandidate signed = await _signedCandidate(
        sender: 'TESTOP',
        provider: 'TEST_PROVIDER',
        template: _knownGoodTemplate,
      );
      final SignedSmsDepositRelease release = (await signed.verifier.verify(
        signed.bundle,
        _now,
      ))!;
      final ProviderDeposit? deposit = const SignedSmsDepositParser().parse(
        NativeSmsRecord(
          id: _testId(0),
          sender: 'TESTOP',
          receivedAt: _receivedAt,
          segments: 1,
          body: _knownGoodBody,
        ),
        release,
        _now,
      );

      expect(deposit, isNotNull);
      expect(deposit!.amountMinor, 12550);
      expect(deposit.currency, 'CDF');
      expect(deposit.providerReference, 'SAMPLE-1234');
      expect(deposit.customerLookupIdentifier, 'test-account-001');
      expect(deposit.providerOccurredAt, '2026-09-05T09:00:00Z');
    },
  );
}
