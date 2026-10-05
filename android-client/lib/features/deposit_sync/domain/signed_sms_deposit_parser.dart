import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import '../../payment_inbox/domain/payment_ingestion.dart';
import '../../sms_gateway/domain/sms_gateway.dart';
import '../presentation/deposit_submission_bloc.dart';

/// Only the verifier creates this authority. Release signatures approve a
/// parser, while the reported transfer still requires settlement verification.
final class SignedSmsDepositRelease {
  const SignedSmsDepositRelease._({
    required this.provider, required this.sender, required this.template,
    required this.version, required this.releaseId, required this.approvedAt, required this.expiresAt,
  });
  final String provider;
  final String sender;
  final DepositSmsTemplate template;
  final int version;
  final String releaseId;
  final DateTime approvedAt;
  final DateTime expiresAt;
}

final class SignedSmsDepositReleaseVerifier {
  const SignedSmsDepositReleaseVerifier({required this.pinnedSigningPublicKey});
  final String pinnedSigningPublicKey;

  Future<SignedSmsDepositRelease?> verify(String bundle, DateTime now) async {
    if (utf8.encode(bundle).length > 12288) return null;
    try {
      final Object? decoded = jsonDecode(bundle);
      if (decoded is! Map<String, dynamic>) return null;
      final Uint8List? key = _base64(pinnedSigningPublicKey, 32);
      if (key == null) return null;
      // PR225's encoded_release is the canonical flat signed object. A wrapper
      // is only an import carrier and can never establish signing authority.
      Map<String, dynamic> release = decoded;
      if (decoded.containsKey('release')) {
        if (decoded.length != 2 || decoded['signing_public_key'] != pinnedSigningPublicKey ||
            decoded['release'] is! Map<String, dynamic>) {
          return null;
        }
        release = decoded['release'] as Map<String, dynamic>;
      }
      const Set<String> keys = <String>{'schema_version', 'provider', 'sender', 'template',
        'pattern_version', 'approved_at', 'expires_at', 'signature'};
      if (release.length != keys.length || !release.keys.every(keys.contains) ||
          release['schema_version'] != '1' || release['provider'] is! String ||
          release['sender'] is! String || release['template'] is! String ||
          release['pattern_version'] is! int || release['approved_at'] is! String ||
          release['expires_at'] is! String || release['signature'] is! String) {
        return null;
      }
      final String provider = release['provider'] as String;
      final String sender = release['sender'] as String;
      final DepositSmsTemplate template = DepositSmsTemplate(release['template'] as String);
      final int version = release['pattern_version'] as int;
      final DateTime? approved = _timestamp(release['approved_at'] as String);
      final DateTime? expiry = _timestamp(release['expires_at'] as String);
      final Uint8List? signature = _base64(release['signature'] as String, 64);
      if (!RegExp(r'^[A-Z0-9._-]{3,32}$').hasMatch(provider) ||
          SenderIdentity.fromOsMetadata(sender)?.value != sender || !template.valid ||
          version < 1 || approved == null || expiry == null || approved.isAfter(now.toUtc()) ||
          !expiry.isAfter(approved) || !expiry.isAfter(now.toUtc()) || signature == null) {
        return null;
      }
      final Uint8List payload = canonicalPayload(release);
      if (!await Ed25519().verify(payload, signature: Signature(signature,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)))) {
        return null;
      }
      return SignedSmsDepositRelease._(provider: provider, sender: sender,
        template: template, version: version, releaseId: sha256.convert(payload).toString(),
        approvedAt: approved, expiresAt: expiry);
    } on Object {
      return null;
    }
  }

  /// Same LP16 context and order as the published backend release.
  static Uint8List canonicalPayload(Map<String, dynamic> release) {
    final BytesBuilder result = BytesBuilder(copy: false);
    for (final String value in <String>['openpaycongo/operator-payment-pattern', '1',
      release['provider'] as String, release['sender'] as String,
      release['template'] as String, '${release['pattern_version']}',
      release['approved_at'] as String, release['expires_at'] as String]) {
      final List<int> bytes = utf8.encode(value);
      result.add(<int>[bytes.length >> 8, bytes.length & 255]);
      result.add(bytes);
    }
    return result.toBytes();
  }

  static Uint8List? _base64(String value, int length) {
    try {
      final Uint8List result = base64Url.decode(base64Url.normalize(value));
      return result.length == length && base64UrlEncode(result).replaceAll('=', '') == value ? result : null;
    } on FormatException { return null; }
  }

  static DateTime? _timestamp(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value)) return null;
    final DateTime? parsed = DateTime.tryParse(value);
    return parsed != null && parsed.toIso8601String().replaceFirst('.000Z', 'Z') == value ? parsed : null;
  }
}

/// Bounded literal scanner adapted from PR225's deterministic parser. No
/// user regex runs and every required deposit field must occur in the SMS.
final class DepositSmsTemplate {
  const DepositSmsTemplate(this.value);
  final String value;
  static const Set<String> fields = <String>{'amount', 'currency', 'reference', 'customer', 'occurred_at'};

  List<({String text, bool field})>? _tokens() {
    if (value.isEmpty || value.length > 512) return null;
    final List<({String text, bool field})> tokens = <({String text, bool field})>[];
    final Set<String> seen = <String>{};
    int cursor = 0;
    while (cursor < value.length) {
      final int open = value.indexOf('{', cursor);
      final int stray = value.indexOf('}', cursor);
      if (stray >= 0 && (open < 0 || stray < open)) return null;
      if (open < 0) { tokens.add((text: value.substring(cursor), field: false)); break; }
      if (open > cursor) tokens.add((text: value.substring(cursor, open), field: false));
      final int close = value.indexOf('}', open + 1);
      if (close < 0) return null;
      final String field = value.substring(open + 1, close);
      if (!fields.contains(field) || !seen.add(field) || (tokens.isNotEmpty && tokens.last.field)) return null;
      tokens.add((text: field, field: true));
      cursor = close + 1;
    }
    return seen.length == fields.length ? tokens : null;
  }

  bool get valid => _tokens() != null;

  Map<String, String>? capture(String body) {
    final List<({String text, bool field})>? tokens = _tokens();
    if (tokens == null) return null;
    final Map<String, String> result = <String, String>{};
    int cursor = 0;
    for (int i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (!token.field) {
        if (!body.startsWith(token.text, cursor)) return null;
        cursor += token.text.length;
      } else {
        final int end = i + 1 == tokens.length ? body.length : body.indexOf(tokens[i + 1].text, cursor);
        if (end <= cursor || end - cursor > 255) return null;
        result[token.text] = body.substring(cursor, end);
        cursor = end;
      }
    }
    return cursor == body.length ? result : null;
  }
}

final class SignedSmsDepositParser {
  const SignedSmsDepositParser();

  ProviderDeposit? parse(NativeSmsRecord record, SignedSmsDepositRelease release, DateTime now) {
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(record.sender);
    final SenderIdentity? expected = SenderIdentity.fromOsMetadata(release.sender);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(record.id) || sender == null || expected == null ||
        record.sender != expected.value || !TrustedSenderRule(expected).allows(sender) ||
        !release.expiresAt.isAfter(now.toUtc()) ||
        record.receivedAt.toUtc().isBefore(release.approvedAt) ||
        !record.receivedAt.toUtc().isBefore(release.expiresAt)) {
      return null;
    }
    final SmsEnvelope? sms = SmsEnvelope.fromOs(sender: sender, body: record.body,
      receivedAt: record.receivedAt, segments: record.segments, now: now);
    if (sms == null) return null;
    final Map<String, String>? values = release.template.capture(sms.body);
    if (values == null || values['currency'] != 'CDF') return null;
    final RegExpMatch? amount = RegExp(r'^([0-9]{1,12})(?:\.([0-9]{1,2}))?$').firstMatch(values['amount']!);
    if (amount == null) return null;
    final int minor = int.parse(amount.group(1)!) * 100 + int.parse((amount.group(2) ?? '0').padRight(2, '0'));
    if (minor <= 0 || !_identifier(values['customer']!) || !_identifier(values['reference']!)) return null;
    final String occurred = values['occurred_at']!;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$').hasMatch(occurred)) return null;
    final DateTime? date = DateTime.tryParse(occurred);
    if (date == null || !_validProviderTime(occurred) || date.isAfter(now.toUtc().add(SmsEnvelope.maxFutureSkew))) return null;
    return ProviderDeposit(customerLookupIdentifier: values['customer']!, providerReference: values['reference']!,
      amountMinor: minor, currency: 'CDF', providerOccurredAt: occurred, senderIdentifier: sender.value,
      parserEvidence: DepositParserEvidence(provider: release.provider, smsSender: sender.value,
        parserVersion: release.version, smsReceivedAt: '${record.receivedAt.toUtc().toIso8601String().split('.').first}Z',
        evidenceDigest: sha256.convert(utf8.encode(record.body)).toString(), parserReleaseId: release.releaseId));
  }

  bool _identifier(String value) => value.isNotEmpty && value.length <= 255 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  bool _validProviderTime(String value) {
    // Dart normalizes invalid calendar dates. Check local components before
    // accepting an explicit provider offset instead of a capture-time guess.
    final String local = value.substring(0, 19);
    final DateTime? parsed = DateTime.tryParse('${local}Z');
    if (parsed == null || parsed.toIso8601String().substring(0, 19) != local) return false;
    return value.endsWith('Z') || (int.parse(value.substring(20, 22)) <= 23 && int.parse(value.substring(23, 25)) <= 59);
  }
}
