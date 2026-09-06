import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../payment_outbox/domain/payment_outbox.dart';
import 'operator_sms_payment_data.dart';
import 'payment_ingestion.dart';

/// A Gemma-authored candidate. It cannot activate a parser by itself.
final class ProposedOperatorPaymentPattern {
  const ProposedOperatorPaymentPattern({
    required this.provider,
    required this.sender,
    required this.template,
    required this.version,
  });
  final String provider;
  final String sender;
  final String template;
  final int version;
}

/// Constructed only after the release signature, shape, binding, and expiry
/// have been verified against a pinned developer signing key.
final class DeveloperApprovedOperatorPaymentPattern {
  const DeveloperApprovedOperatorPaymentPattern._({
    required this.proposal,
    required this.approvedAt,
    required this.expiresAt,
  });
  final ProposedOperatorPaymentPattern proposal;
  final DateTime approvedAt;
  final DateTime expiresAt;
}

final class DeveloperApprovedOperatorPaymentPatternVerifier {
  const DeveloperApprovedOperatorPaymentPatternVerifier();

  static const Set<String> _keys = <String>{
    'schema_version', 'provider', 'sender', 'template', 'pattern_version',
    'approved_at', 'expires_at', 'signature',
  };
  static final RegExp _provider = RegExp(r'^[A-Z0-9._-]{3,32}$');
  static final RegExp _signature = RegExp(r'^[A-Za-z0-9_-]{86}$');
  static final RegExp _timestamp = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$');

  Future<DeveloperApprovedOperatorPaymentPattern?> verify({
    required String encodedRelease,
    required Uint8List pinnedSigningKey,
    required DateTime now,
  }) async {
    if (encodedRelease.length > 8192 || pinnedSigningKey.length != 32) {
      return null;
    }
    final Map<String, Object?>? fields = _fields(encodedRelease);
    if (fields == null) return null;
    final String schema = fields['schema_version']! as String;
    final String provider = fields['provider']! as String;
    final String sender = fields['sender']! as String;
    final String template = fields['template']! as String;
    final int version = fields['pattern_version']! as int;
    final String approved = fields['approved_at']! as String;
    final String expires = fields['expires_at']! as String;
    final Uint8List? signature = _signatureBytes(fields['signature']! as String);
    final DateTime? approvedAt = _time(approved);
    final DateTime? expiresAt = _time(expires);
    if (schema != '1' || !_provider.hasMatch(provider) ||
        SenderIdentity.fromOsMetadata(sender) == null ||
        !PaymentTemplate(template).valid || version <= 0 ||
        approvedAt == null || expiresAt == null || !expiresAt.isAfter(approvedAt) ||
        !expiresAt.isAfter(now.toUtc()) || signature == null) {
      return null;
    }
    final bool valid;
    try {
      valid = await Ed25519().verify(
        canonicalPayload(schema: schema, provider: provider, sender: sender,
          template: template, version: version, approvedAt: approved, expiresAt: expires),
        signature: Signature(signature, publicKey: SimplePublicKey(pinnedSigningKey, type: KeyPairType.ed25519)),
      );
    } on Object {
      return null;
    }
    if (!valid) {
      return null;
    }
    return DeveloperApprovedOperatorPaymentPattern._(
      proposal: ProposedOperatorPaymentPattern(provider: provider, sender: sender, template: template, version: version),
      approvedAt: approvedAt, expiresAt: expiresAt,
    );
  }

  static Uint8List canonicalPayload({
    required String schema, required String provider, required String sender,
    required String template, required int version, required String approvedAt,
    required String expiresAt,
  }) {
    final BytesBuilder result = BytesBuilder(copy: false);
    for (final String field in <String>[
      'openpaycongo/operator-payment-pattern', schema, provider, sender,
      template, '$version', approvedAt, expiresAt,
    ]) {
      final Uint8List bytes = Uint8List.fromList(utf8.encode(field));
      result.add(<int>[bytes.length >> 8, bytes.length & 0xff]);
      result.add(bytes);
    }
    return result.toBytes();
  }

  Map<String, Object?>? _fields(String input) {
    final Object value;
    try {
      value = jsonDecode(input);
    } on FormatException {
      return null;
    }
    if (value is! Map<Object?, Object?> || value.length != _keys.length) {
      return null;
    }
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (entry.key is! String || !_keys.contains(entry.key)) {
        return null;
      }
      result[entry.key! as String] = entry.value;
    }
    if (result['schema_version'] is! String || result['provider'] is! String ||
        result['sender'] is! String || result['template'] is! String ||
        result['pattern_version'] is! int || result['approved_at'] is! String ||
        result['expires_at'] is! String || result['signature'] is! String) {
      return null;
    }
    return result;
  }

  DateTime? _time(String value) {
    if (!_timestamp.hasMatch(value)) {
      return null;
    }
    try {
      final DateTime parsed = DateTime.parse(value).toUtc();
      return parsed.toIso8601String().replaceFirst('.000Z', 'Z') == value ? parsed : null;
    } on FormatException {
      return null;
    }
  }

  Uint8List? _signatureBytes(String value) {
    if (!_signature.hasMatch(value)) {
      return null;
    }
    try {
      final Uint8List bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
      return bytes.length == 64 && base64UrlEncode(bytes).replaceAll('=', '') == value ? bytes : null;
    } on FormatException {
      return null;
    }
  }
}

final class PendingOperatorSms {
  const PendingOperatorSms({required this.sourceRecordId, required this.sms});
  final String sourceRecordId;
  final SmsEnvelope sms;
}

final class PendingPatternReview {
  const PendingPatternReview({required this.sourceRecordId, required this.reason});
  final String sourceRecordId;
  final String reason;
}

final class PatternBacklogReanalysis {
  const PatternBacklogReanalysis({required this.pushReady, required this.needsReview});
  final List<CapturedPaymentForPush> pushReady;
  final List<PendingPatternReview> needsReview;
}

/// Activation accepts no proposal. Verified developer authority is a type-level
/// precondition; this code has no queue, network, or inbox-acknowledgement side effect.
final class ApprovedOperatorPatternActivation {
  const ApprovedOperatorPatternActivation();

  PatternBacklogReanalysis reanalyse({
    required DeveloperApprovedOperatorPaymentPattern release,
    required List<PendingOperatorSms> pending,
    required OutboxScope scope,
  }) {
    final ProposedOperatorPaymentPattern proposal = release.proposal;
    final SenderIdentity sender = SenderIdentity.fromOsMetadata(proposal.sender)!;
    final OperatorSmsPaymentProfile profile = OperatorSmsPaymentProfile(
      provider: proposal.provider, senderRule: TrustedSenderRule(sender),
      structure: ManualPaymentStructure(PaymentTemplate(proposal.template)),
    );
    final List<CapturedPaymentForPush> ready = <CapturedPaymentForPush>[];
    final List<PendingPatternReview> review = <PendingPatternReview>[];
    final Set<String> seen = <String>{};
    for (final PendingOperatorSms item in pending) {
      if (!seen.add(item.sourceRecordId) || item.sms.sender != sender) {
        continue;
      }
      switch (const OperatorSmsPaymentDataFactory().interpret(
        sourceRecordId: item.sourceRecordId,
        sms: item.sms,
        profile: profile,
        scope: scope,
        provenance: PaymentParserProvenance.developerApprovedPattern(
          proposal.version,
        ),
      )) {
        case PaymentDataReadyForPush(:final data): ready.add(data);
        case PaymentDataNeedsReview(:final String reason):
          review.add(PendingPatternReview(sourceRecordId: item.sourceRecordId, reason: reason));
      }
    }
    return PatternBacklogReanalysis(
      pushReady: List<CapturedPaymentForPush>.unmodifiable(ready),
      needsReview: List<PendingPatternReview>.unmodifiable(review),
    );
  }
}
