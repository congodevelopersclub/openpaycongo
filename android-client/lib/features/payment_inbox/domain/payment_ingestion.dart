import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

sealed class SenderIdentity {
  const SenderIdentity._(this.value);
  final String value;

  static SenderIdentity? fromOsMetadata(String value) {
    final String candidate = value.trim();
    if (RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(candidate)) {
      return PhoneSender._(candidate);
    }
    if (RegExp(r'^[A-Z0-9]{3,11}$').hasMatch(candidate)) {
      return AlphaSender._(candidate);
    }
    return null;
  }
}

final class PhoneSender extends SenderIdentity {
  const PhoneSender._(super.value) : super._();
}

final class AlphaSender extends SenderIdentity {
  const AlphaSender._(super.value) : super._();
}

final class TrustedSenderRule {
  const TrustedSenderRule(this.sender);
  final SenderIdentity sender;

  bool allows(SenderIdentity actual) =>
      actual.runtimeType == sender.runtimeType && actual.value == sender.value;
}

final class SmsEnvelope {
  const SmsEnvelope._(this.sender, this.body, this.receivedAt, this.segments);

  static const int maxBytes = 4096;
  static const int maxSegments = 8;
  static const Duration maxAge = Duration(days: 31);
  static const Duration maxFutureSkew = Duration(minutes: 5);

  final SenderIdentity sender;
  final String body;
  final DateTime receivedAt;
  final int segments;

  static SmsEnvelope? fromOs({
    required SenderIdentity sender,
    required String body,
    required DateTime receivedAt,
    required int segments,
    required DateTime now,
  }) {
    final Duration age = now.toUtc().difference(receivedAt.toUtc());
    if (segments < 1 ||
        segments > maxSegments ||
        age > maxAge ||
        age < -maxFutureSkew ||
        utf8.encode(body).length > maxBytes) {
      return null;
    }
    return SmsEnvelope._(sender, body, receivedAt.toUtc(), segments);
  }
}

enum ReviewState { trusted, needsReview, rejected }

final class PaymentCandidate {
  const PaymentCandidate({
    required this.amountMinor,
    required this.currency,
    required this.reference,
    required this.provider,
  });
  final int amountMinor;
  final String currency;
  final String reference;
  final String provider;
}

sealed class ParseDecision {
  const ParseDecision();
}

final class Rejected extends ParseDecision {
  const Rejected(this.reason);
  final String reason;
}

final class NeedsReview extends ParseDecision {
  const NeedsReview(this.reason, {this.candidate});
  final String reason;
  final PaymentCandidate? candidate;
}

final class TrustedCandidate extends ParseDecision {
  const TrustedCandidate(this.value);
  final PaymentCandidate value;
}

enum TemplateField { amount, currency, reference }

sealed class TemplateToken {
  const TemplateToken();
}

final class LiteralToken extends TemplateToken {
  const LiteralToken(this.value);
  final String value;
}

final class FieldToken extends TemplateToken {
  const FieldToken(this.field);
  final TemplateField field;
}

final class PaymentTemplate {
  const PaymentTemplate(this.value);
  static const int maxLength = 512;
  final String value;

  List<TemplateToken>? tokens() {
    if (value.isEmpty || value.length > maxLength) return null;
    final List<TemplateToken> result = <TemplateToken>[];
    final Set<TemplateField> seen = <TemplateField>{};
    int cursor = 0;
    while (cursor < value.length) {
      final int opening = value.indexOf('{', cursor);
      if (opening < 0) {
        if (value.indexOf('}', cursor) >= 0) return null;
        result.add(LiteralToken(value.substring(cursor)));
        break;
      }
      if (value.indexOf('}', cursor) >= 0 &&
          value.indexOf('}', cursor) < opening) {
        return null;
      }
      if (opening > cursor) {
        result.add(LiteralToken(value.substring(cursor, opening)));
      }
      final int closing = value.indexOf('}', opening + 1);
      if (closing < 0) return null;
      final TemplateField? field = switch (value.substring(
        opening + 1,
        closing,
      )) {
        'amount' => TemplateField.amount,
        'currency' => TemplateField.currency,
        'reference' => TemplateField.reference,
        _ => null,
      };
      if (field == null || !seen.add(field)) return null;
      if (result.isNotEmpty && result.last is FieldToken) return null;
      result.add(FieldToken(field));
      cursor = closing + 1;
    }
    if (seen.length != TemplateField.values.length) return null;
    return List<TemplateToken>.unmodifiable(result);
  }

  bool get valid => tokens() != null;
}

final class DeterministicPaymentParser {
  const DeterministicPaymentParser();

  ParseDecision parse(
    SmsEnvelope envelope,
    TrustedSenderRule rule,
    PaymentTemplate template,
  ) {
    if (!rule.allows(envelope.sender)) {
      return const Rejected('untrusted_sender');
    }
    final List<TemplateToken>? tokens = template.tokens();
    if (tokens == null) return const NeedsReview('invalid_template');
    final Map<TemplateField, String> values = <TemplateField, String>{};
    int cursor = 0;
    for (int index = 0; index < tokens.length; index += 1) {
      final TemplateToken token = tokens[index];
      if (token is LiteralToken) {
        if (!envelope.body.startsWith(token.value, cursor)) {
          return const NeedsReview('template_literal_mismatch');
        }
        cursor += token.value.length;
        continue;
      }
      final FieldToken field = token as FieldToken;
      LiteralToken? nextLiteral;
      for (int next = index + 1; next < tokens.length; next += 1) {
        if (tokens[next] is LiteralToken) {
          nextLiteral = tokens[next] as LiteralToken;
          break;
        }
      }
      final int end = nextLiteral == null
          ? envelope.body.length
          : envelope.body.indexOf(nextLiteral.value, cursor);
      if (end < cursor || end - cursor > 128) {
        return const NeedsReview('template_field_missing_or_oversized');
      }
      final String capture = envelope.body.substring(cursor, end);
      if (capture.isEmpty) return const NeedsReview('template_field_empty');
      values[field.field] = capture;
      cursor = end;
    }
    if (cursor != envelope.body.length) {
      return const NeedsReview('template_trailing_data');
    }
    return _validateFields(values, envelope.sender.value);
  }

  ParseDecision _validateFields(
    Map<TemplateField, String> values,
    String provider,
  ) {
    final String amount = values[TemplateField.amount] ?? '';
    final RegExpMatch? amountMatch = RegExp(
      r'^([0-9]{1,12})(?:\.([0-9]{1,2}))?$',
    ).firstMatch(amount);
    final String currency = values[TemplateField.currency] ?? '';
    if (amountMatch == null || (currency != 'CDF' && currency != 'USD')) {
      return const NeedsReview('ambiguous_amount_or_currency');
    }
    final String reference = values[TemplateField.reference] ?? '';
    if (!RegExp(r'^[A-Z0-9-]{4,64}$').hasMatch(reference)) {
      return const NeedsReview('invalid_reference');
    }
    final int amountMinor =
        int.parse(amountMatch.group(1)!) * 100 +
        int.parse((amountMatch.group(2) ?? '0').padRight(2, '0'));
    if (amountMinor <= 0) return const NeedsReview('invalid_amount');
    return TrustedCandidate(
      PaymentCandidate(
        amountMinor: amountMinor,
        currency: currency,
        reference: reference,
        provider: provider,
      ),
    );
  }
}

enum SmsPermissionState {
  unavailable,
  needsDefaultRole,
  needsRuntimeGrant,
  denied,
  permanentlyDenied,
  ready,
}

abstract interface class SmsCapabilityPort {
  Future<SmsPermissionState> state();
  Future<SmsPermissionState> requestInContext();
}

sealed class GemmaCapabilityEvidence {
  const GemmaCapabilityEvidence();
}

final class GemmaUnavailable extends GemmaCapabilityEvidence {
  const GemmaUnavailable();
}

final class GemmaModelMissing extends GemmaCapabilityEvidence {
  const GemmaModelMissing();
}

final class GemmaRuntimePending extends GemmaCapabilityEvidence {
  const GemmaRuntimePending();
}

final class ModelPackageDescriptor {
  const ModelPackageDescriptor({
    required this.sha256Hex,
    required this.signature,
  });
  final String sha256Hex;
  final String signature;
}

abstract interface class ModelPackageVerifier {
  Future<bool> verify(ModelPackageDescriptor descriptor);
}

abstract interface class GemmaProposalPort {
  Future<String> proposeJson(SmsEnvelope envelope, Duration timeout);
}

final class ProposalValidator {
  const ProposalValidator();

  ParseDecision validate(
    String proposalJson,
    SmsEnvelope envelope,
    TrustedSenderRule rule, {
    Set<String> seenProviderReferences = const <String>{},
  }) {
    if (!rule.allows(envelope.sender)) {
      return const Rejected('untrusted_sender');
    }
    if (utf8.encode(proposalJson).length > 2048) {
      return const NeedsReview('model_proposal_oversized');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(proposalJson);
    } on FormatException {
      return const NeedsReview('model_malformed_json');
    }
    if (decoded is! Map<String, dynamic>) {
      return const NeedsReview('model_invalid_schema');
    }
    const Set<String> expected = <String>{
      'amount_minor',
      'currency',
      'reference',
      'provider',
      'confidence',
    };
    if (decoded.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(decoded.keys.toSet()).isNotEmpty) {
      return const NeedsReview('model_invalid_schema');
    }
    final Object? amount = decoded['amount_minor'];
    final Object? currency = decoded['currency'];
    final Object? reference = decoded['reference'];
    final Object? provider = decoded['provider'];
    final Object? confidence = decoded['confidence'];
    if (amount is! int ||
        amount <= 0 ||
        currency is! String ||
        (currency != 'CDF' && currency != 'USD') ||
        reference is! String ||
        !RegExp(r'^[A-Z0-9-]{4,64}$').hasMatch(reference) ||
        provider is! String ||
        provider != envelope.sender.value ||
        confidence is! num ||
        confidence < 0 ||
        confidence > 1) {
      return const NeedsReview('model_invalid_fields');
    }
    if (seenProviderReferences.contains('$provider:$reference')) {
      return const NeedsReview('model_duplicate_reference');
    }
    final PaymentCandidate candidate = PaymentCandidate(
      amountMinor: amount,
      currency: currency,
      reference: reference,
      provider: provider,
    );
    if (confidence < 0.90) {
      return NeedsReview('model_low_confidence', candidate: candidate);
    }
    return NeedsReview(
      'model_proposal_requires_human_review',
      candidate: candidate,
    );
  }
}

final class EnvelopeKey {
  const EnvelopeKey._(this.value);
  final String value;

  static EnvelopeKey? derive({
    required String deviceId,
    required SmsEnvelope envelope,
    required String providerReference,
  }) {
    if (!RegExp(r'^[A-Za-z0-9._-]{8,64}$').hasMatch(deviceId) ||
        !RegExp(r'^[A-Z0-9-]{4,64}$').hasMatch(providerReference)) {
      return null;
    }
    final List<String> fields = <String>[
      deviceId,
      envelope.sender.value,
      envelope.receivedAt.toIso8601String(),
      envelope.body,
      providerReference,
    ];
    final String canonical = fields
        .map((String field) => '${utf8.encode(field).length}:$field')
        .join('|');
    return EnvelopeKey._(sha256.convert(utf8.encode(canonical)).toString());
  }
}

final class MinimizedEnvelope {
  const MinimizedEnvelope({
    required this.key,
    required this.sender,
    required this.receivedAt,
    required this.providerReference,
    required this.redactedBody,
  });
  final EnvelopeKey key;
  final SenderIdentity sender;
  final DateTime receivedAt;
  final String providerReference;
  final String redactedBody;
}

abstract interface class DurableEncryptedInboxVault {
  Future<bool> persistIfAbsent(MinimizedEnvelope envelope);
}

/// Test fake only. It is neither durable nor encrypted.
final class InMemoryVault implements DurableEncryptedInboxVault {
  final Set<String> _keys = <String>{};
  final Set<String> _providerReferences = <String>{};

  @override
  Future<bool> persistIfAbsent(MinimizedEnvelope envelope) async {
    final String providerKey =
        '${envelope.sender.value}:${envelope.providerReference}';
    if (_keys.contains(envelope.key.value) ||
        _providerReferences.contains(providerKey)) {
      return false;
    }
    _keys.add(envelope.key.value);
    _providerReferences.add(providerKey);
    return true;
  }
}

abstract interface class Clock {
  DateTime nowUtc();
}

final class SystemClock implements Clock {
  const SystemClock();
  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

final class BoundedProposalRunner {
  BoundedProposalRunner({
    required this.port,
    required this.clock,
    this.requestTimeout = const Duration(seconds: 3),
    this.hardTimeout = const Duration(seconds: 4),
    this.failureLimit = 3,
    this.cooldown = const Duration(minutes: 5),
  }) : assert(failureLimit > 0),
       assert(hardTimeout > Duration.zero);

  final GemmaProposalPort port;
  final Clock clock;
  final Duration requestTimeout;
  final Duration hardTimeout;
  final int failureLimit;
  final Duration cooldown;
  int _failures = 0;
  DateTime? _openUntil;

  Future<ParseDecision> run(
    SmsEnvelope envelope,
    TrustedSenderRule rule,
  ) async {
    if (!rule.allows(envelope.sender)) {
      return const Rejected('untrusted_sender');
    }
    final DateTime now = clock.nowUtc();
    if (_openUntil case final DateTime until when now.isBefore(until)) {
      return const NeedsReview('model_circuit_open_use_manual_parser');
    }
    try {
      final String json = await port
          .proposeJson(envelope, requestTimeout)
          .timeout(hardTimeout);
      _failures = 0;
      _openUntil = null;
      return const ProposalValidator().validate(json, envelope, rule);
    } on TimeoutException {
      _recordFailure(now);
      return const NeedsReview('model_timeout_use_manual_parser');
    } on Exception {
      _recordFailure(now);
      return const NeedsReview('model_unavailable_use_manual_parser');
    }
  }

  void _recordFailure(DateTime now) {
    _failures += 1;
    if (_failures >= failureLimit) _openUntil = now.add(cooldown);
  }
}
