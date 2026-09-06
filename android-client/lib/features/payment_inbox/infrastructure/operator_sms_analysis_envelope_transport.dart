import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../deposit_sync/data/mobile_deposit_http_transport.dart';
import '../../deposit_sync/data/mobile_envelope_sealer.dart';

/// The only HTTP path for raw SMS evidence. It requires a prior explicit
/// consent decision, seals the evidence in native code, and accepts only the
/// authenticated encrypted acknowledgement from the paired server.
final class OperatorSmsAnalysisEnvelopeTransport {
  OperatorSmsAnalysisEnvelopeTransport({
    required this.vault,
    required this.http,
    this.timeout = const Duration(seconds: 3),
  });

  final MobileEnvelopeSealer vault;
  final MobileDepositHttpPort http;
  final Duration timeout;

  Future<OperatorSmsAnalysisSubmission> submit(
    OperatorSmsAnalysisEvidence evidence,
  ) async {
    final Uint8List payload = Uint8List.fromList(
      utf8.encode(jsonEncode(evidence.json())),
    );
    try {
      final MobileRequestEnvelope envelope =
          await vault.sealOperatorSmsInterpretationRequest(payload);
      final MobileDepositHttpExchange exchange = http.post(
        MobileDepositHttpRequest(
          uri: _endpointFor(envelope.serverBaseUrl),
          headers: <String, String>{
            HttpHeaders.acceptHeader: ContentType.json.mimeType,
            HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          },
          body: utf8.encode(jsonEncode(<String, Object>{
            'version': envelope.version,
            'installation_id': envelope.installationId,
            'counter': envelope.counter,
            'nonce': envelope.nonce,
            'ciphertext': envelope.ciphertext,
          })),
        ),
      );
      final MobileDepositHttpResponse response = await exchange.response.timeout(
        timeout,
        onTimeout: () {
          exchange.abort();
          throw const OperatorSmsAnalysisUnavailable();
        },
      );
      if (response.body.length > 1024) throw const OperatorSmsAnalysisUnavailable();
      final Object? decoded = jsonDecode(utf8.decode(response.body, allowMalformed: false));
      if (decoded is! Map<Object?, Object?> ||
          decoded.length != 3 ||
          decoded['version'] != 1 ||
          decoded['nonce'] is! String ||
          decoded['ciphertext'] is! String) {
        throw const OperatorSmsAnalysisUnavailable();
      }
      final MobileEnvelopeResponseOutcome outcome = await vault.openOperatorSmsInterpretationResponse(
        request: envelope,
        status: response.status,
        nonce: decoded['nonce'] as String,
        ciphertext: decoded['ciphertext'] as String,
      );
      return switch (outcome) {
        MobileEnvelopeResponseOutcome.recorded => const OperatorSmsAnalysisSubmitted(),
        MobileEnvelopeResponseOutcome.replayed => const OperatorSmsAnalysisAlreadySubmitted(),
        MobileEnvelopeResponseOutcome.conflict => throw const OperatorSmsAnalysisUnavailable(),
      };
    } on OperatorSmsAnalysisUnavailable {
      rethrow;
    } on Object {
      throw const OperatorSmsAnalysisUnavailable();
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  Uri _endpointFor(String baseUrl) {
    final Uri base = Uri.parse(baseUrl);
    if (base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        (base.path.isNotEmpty && base.path != '/') ||
        base.hasQuery ||
        base.hasFragment ||
        base.toString() != baseUrl) {
      throw const OperatorSmsAnalysisUnavailable();
    }
    return base.replace(path: '/mobile/envelopes', query: null, fragment: null);
  }
}

final class OperatorSmsAnalysisEvidence {
  const OperatorSmsAnalysisEvidence({
    required this.recordId,
    required this.provider,
    required this.sender,
    required this.body,
    required this.receivedAt,
  });
  final String recordId;
  final String provider;
  final String sender;
  final String body;
  final DateTime receivedAt;
  Map<String, Object> json() {
    final DateTime utc = receivedAt.toUtc();
    final DateTime canonicalSecond = DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
    );
    return <String, Object>{
      'record_id': recordId,
      'provider': provider,
      'sender': sender,
      'sms_body': body,
      // The encrypted server contract intentionally accepts only canonical UTC
      // whole seconds. Dart serializes zero milliseconds as `.000Z`, so strip
      // that representation rather than widening the server's input surface.
      'received_at': canonicalSecond
          .toIso8601String()
          .replaceFirst(RegExp(r'\.000Z$'), 'Z'),
    };
  }
}

sealed class OperatorSmsAnalysisSubmission {
  const OperatorSmsAnalysisSubmission();
}

final class OperatorSmsAnalysisSubmitted extends OperatorSmsAnalysisSubmission {
  const OperatorSmsAnalysisSubmitted();
}

final class OperatorSmsAnalysisAlreadySubmitted
    extends OperatorSmsAnalysisSubmission {
  const OperatorSmsAnalysisAlreadySubmitted();
}

final class OperatorSmsAnalysisUnavailable implements Exception {
  const OperatorSmsAnalysisUnavailable();
}
