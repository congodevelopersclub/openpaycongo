import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'platform_pairing_activation_vault.dart';
import '../presentation/pairing_protocol_bloc.dart';
import '../presentation/pairing_v2_completion.dart';

abstract interface class PairingActivationRetrievalTransport {
  Future<PairingActivationEnvelope> retrieve(Uri completionEndpoint, Uint8List intentId);
}

final class PairingActivationEnvelope {
  PairingActivationEnvelope({required this.nonce, required this.ciphertext});

  final Uint8List nonce;
  final Uint8List ciphertext;

  void dispose() {
    nonce.fillRange(0, nonce.length, 0);
    ciphertext.fillRange(0, ciphertext.length, 0);
  }
}

/// HTTPS-only retrieval. No auth header or credential is sent to this route.
final class DartIoPairingActivationRetrievalTransport
    implements PairingActivationRetrievalTransport {
  DartIoPairingActivationRetrievalTransport({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;
  static const int _maximumResponseBytes = 8192;

  @override
  Future<PairingActivationEnvelope> retrieve(Uri completionEndpoint, Uint8List intentId) async {
    final Uri endpoint = _activationEndpoint(completionEndpoint, intentId);
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _retrieve(client, endpoint).timeout(timeout);
    } on TimeoutException {
      throw const PairingActivationRetrievalFailure();
    } on HttpException {
      throw const PairingActivationRetrievalFailure();
    } on SocketException {
      throw const PairingActivationRetrievalFailure();
    } finally {
      client.close(force: true);
    }
  }

  Future<PairingActivationEnvelope> _retrieve(HttpClient client, Uri endpoint) async {
    final HttpClientRequest request = await client.getUrl(endpoint);
    request
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok || response.contentLength > _maximumResponseBytes) {
      throw const PairingActivationRetrievalFailure();
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      body.add(chunk);
      if (body.length > _maximumResponseBytes) throw const PairingActivationRetrievalFailure();
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(body.takeBytes(), allowMalformed: false));
      if (decoded is! Map<String, dynamic> || decoded.length != 3 || decoded['version'] != 2 ||
          decoded['nonce'] is! String || decoded['ciphertext'] is! String) {
        throw const PairingActivationRetrievalFailure();
      }
      final Uint8List nonce = _canonicalBase64Url(decoded['nonce'] as String);
      final Uint8List ciphertext = _canonicalBase64Url(decoded['ciphertext'] as String);
      if (nonce.length != 24 || ciphertext.length < 17 || ciphertext.length > _maximumResponseBytes) {
        nonce.fillRange(0, nonce.length, 0);
        ciphertext.fillRange(0, ciphertext.length, 0);
        throw const PairingActivationRetrievalFailure();
      }
      return PairingActivationEnvelope(nonce: nonce, ciphertext: ciphertext);
    } on FormatException {
      throw const PairingActivationRetrievalFailure();
    }
  }
}

final class PairingActivationRetrievalFailure implements Exception {
  const PairingActivationRetrievalFailure();
}

/// Opaque bridge: encrypted envelope enters native vault, outcome only leaves.
final class PairingActivationConsumer {
  PairingActivationConsumer({required this.transport, required this.vault});

  final PairingActivationRetrievalTransport transport;
  final PlatformPairingActivationVault vault;

  Future<PairingActivationConsumeResult> retrieveAndConsume({
    required Uri completionEndpoint,
    required Uint8List intentId,
  }) async {
    PairingActivationEnvelope? envelope;
    try {
      envelope = await transport.retrieve(completionEndpoint, intentId);
      return await vault.consume(
        intentId: intentId,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
      );
    } on Object {
      return PairingActivationConsumeResult.recoveryRequired;
    } finally {
      envelope?.dispose();
    }
  }
}

final class PairingV2ActivationPort implements PairingActivationPort {
  PairingV2ActivationPort({required this.consumer});

  final PairingActivationConsumer consumer;

  @override
  Future<PairingActivationOutcome> activate(PairingActivationRequest request) async {
    if (request is! PairingV2ActivationRequest) return PairingActivationOutcome.recoveryRequired;
    Uint8List? intentId;
    try {
      intentId = request.takeIntentId();
      final PairingActivationConsumeResult result = await consumer.retrieveAndConsume(
        completionEndpoint: request.completionEndpoint,
        intentId: intentId,
      );
      return result == PairingActivationConsumeResult.activated
          ? PairingActivationOutcome.activated
          : PairingActivationOutcome.recoveryRequired;
    } on Object {
      return PairingActivationOutcome.recoveryRequired;
    } finally {
      intentId?.fillRange(0, intentId.length, 0);
    }
  }
}

Uri _activationEndpoint(Uri completionEndpoint, Uint8List intentId) {
  if (completionEndpoint.scheme != 'https' || !completionEndpoint.hasAuthority ||
      completionEndpoint.userInfo.isNotEmpty || completionEndpoint.path != '/v1/pairing/complete' ||
      completionEndpoint.hasQuery || completionEndpoint.hasFragment || intentId.length != 16) {
    throw const PairingActivationRetrievalFailure();
  }
  return completionEndpoint.replace(
    path: '/v1/pairing/intents/${base64UrlEncode(intentId).replaceAll('=', '')}/activation',
  );
}

Uint8List _canonicalBase64Url(String value) {
  try {
    final Uint8List bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
    if (base64UrlEncode(bytes).replaceAll('=', '') != value) throw const FormatException();
    return bytes;
  } on FormatException {
    throw const PairingActivationRetrievalFailure();
  }
}
