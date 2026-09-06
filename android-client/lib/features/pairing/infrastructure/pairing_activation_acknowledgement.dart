import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../presentation/pairing_protocol_bloc.dart';

/// Routing-safe outer envelope. It contains no pairing credential or key.
final class PairingActivationAcknowledgementEnvelope {
  const PairingActivationAcknowledgementEnvelope({
    required this.serverBaseUrl,
    required this.installationId,
    required this.counter,
    required this.nonce,
    required this.ciphertext,
  });

  final String serverBaseUrl;
  final String installationId;
  final String counter;
  final String nonce;
  final String ciphertext;
}

/// The only HTTP result allowed back to the acknowledgement port.
final class PairingActivationAcknowledgementHttpResponse {
  const PairingActivationAcknowledgementHttpResponse({
    required this.status,
    required this.nonce,
    required this.ciphertext,
  });

  final int status;
  final String nonce;
  final String ciphertext;
}

typedef PairingActivationAcknowledgementPost =
    Future<PairingActivationAcknowledgementHttpResponse?> Function(
      HttpClient client,
      PairingActivationAcknowledgementEnvelope envelope,
    );

/// Native bridge; native code alone can mark the installation active.
final class PlatformPairingActivationAcknowledgementVault {
  const PlatformPairingActivationAcknowledgementVault()
    : _channel = const MethodChannel('openpaycongo/pairing_activation');

  final MethodChannel _channel;

  Future<PairingActivationAcknowledgementRecovery> restore() async {
    try {
      final String? state = await _channel.invokeMethod<String>('acknowledgementState');
      return switch (state) {
        'none' => PairingActivationAcknowledgementRecovery.none,
        'pending' => PairingActivationAcknowledgementRecovery.pending,
        'active' => PairingActivationAcknowledgementRecovery.active,
        _ => PairingActivationAcknowledgementRecovery.recoveryRequired,
      };
    } on PlatformException {
      return PairingActivationAcknowledgementRecovery.recoveryRequired;
    }
  }

  Future<PairingActivationAcknowledgementEnvelope> seal() async {
    try {
      final Map<Object?, Object?>? value = await _channel.invokeMapMethod<Object?, Object?>(
        'sealAcknowledgement',
      );
      const Set<String> fields = <String>{
        'version',
        'server_base_url',
        'installation_id',
        'counter',
        'nonce',
        'ciphertext',
      };
      if (value == null ||
          value.length != fields.length ||
          value.keys.any((Object? key) => key is! String || !fields.contains(key)) ||
          value['version'] != 1) {
        throw const FormatException();
      }
      final String? serverBaseUrl = value['server_base_url'] as String?;
      final String? installationId = value['installation_id'] as String?;
      final String? counter = value['counter'] as String?;
      final String? nonce = value['nonce'] as String?;
      final String? ciphertext = value['ciphertext'] as String?;
      if (serverBaseUrl == null || installationId == null || counter == null || nonce == null || ciphertext == null) {
        throw const FormatException();
      }
      return PairingActivationAcknowledgementEnvelope(
        serverBaseUrl: serverBaseUrl,
        installationId: installationId,
        counter: counter,
        nonce: nonce,
        ciphertext: ciphertext,
      );
    } on PlatformException {
      throw StateError('Pairing activation acknowledgement is unavailable');
    } on FormatException {
      throw StateError('Pairing activation acknowledgement is unavailable');
    }
  }

  Future<bool> open({
    required PairingActivationAcknowledgementEnvelope request,
    required int status,
    required String nonce,
    required String ciphertext,
  }) async {
    try {
      final String? result = await _channel.invokeMethod<String>(
        'openAcknowledgement',
        <String, Object>{
          'installation_id': request.installationId,
          'counter': request.counter,
          'status': status,
          'nonce': nonce,
          'ciphertext': ciphertext,
        },
      );
      return result == 'acknowledged';
    } on PlatformException {
      return false;
    }
  }
}

/// Posts only a native-sealed envelope. A missing or unauthenticated response
/// stays pending; the native counter makes the next retry distinct and safe.
final class PairingV2ActivationAcknowledgementPort
    implements PairingActivationAcknowledgementPort {
  PairingV2ActivationAcknowledgementPort({
    required this.vault,
    this.timeout = const Duration(seconds: 15),
    PairingActivationAcknowledgementPost? post,
    HttpClient Function()? httpClientFactory,
  }) : _post = post ?? _postEnvelope,
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final PlatformPairingActivationAcknowledgementVault vault;
  final Duration timeout;
  final PairingActivationAcknowledgementPost _post;
  final HttpClient Function() _httpClientFactory;
  static const int _maximumResponseBytes = 1024;

  @override
  Future<PairingActivationAcknowledgementRecovery> restore() => vault.restore();

  @override
  Future<PairingActivationAcknowledgementOutcome> acknowledge() async {
    PairingActivationAcknowledgementEnvelope envelope;
    try {
      envelope = await vault.seal();
    } on Object {
      return PairingActivationAcknowledgementOutcome.recoveryRequired;
    }
    final HttpClient client = _httpClientFactory();
    try {
      final PairingActivationAcknowledgementHttpResponse? response =
          await _post(client, envelope).timeout(timeout);
      if (response == null) {
        return PairingActivationAcknowledgementOutcome.retryable;
      }
      return await vault.open(
        request: envelope,
        status: response.status,
        nonce: response.nonce,
        ciphertext: response.ciphertext,
      )
          ? PairingActivationAcknowledgementOutcome.acknowledged
          : PairingActivationAcknowledgementOutcome.retryable;
    } on Object {
      return PairingActivationAcknowledgementOutcome.retryable;
    } finally {
      client.close(force: true);
    }
  }

  static Future<PairingActivationAcknowledgementHttpResponse?> _postEnvelope(
    HttpClient client,
    PairingActivationAcknowledgementEnvelope envelope,
  ) async {
    final Uri endpoint = _endpointFor(envelope.serverBaseUrl);
    final HttpClientRequest request = await client.postUrl(endpoint);
    request
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType)
      ..write(jsonEncode(<String, Object>{
        'version': 1,
        'installation_id': envelope.installationId,
        'counter': envelope.counter,
        'nonce': envelope.nonce,
        'ciphertext': envelope.ciphertext,
      }));
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.created ||
        response.contentLength > _maximumResponseBytes) {
      return null;
    }
    final List<int> body = <int>[];
    await for (final List<int> chunk in response) {
      body.addAll(chunk);
      if (body.length > _maximumResponseBytes) return null;
    }
    final ({String nonce, String ciphertext}) outer = _responseOuter(body);
    return PairingActivationAcknowledgementHttpResponse(
      status: response.statusCode,
      nonce: outer.nonce,
      ciphertext: outer.ciphertext,
    );
  }

  static Uri _endpointFor(String serverBaseUrl) {
    final Uri base = Uri.parse(serverBaseUrl);
    if (base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        (base.path.isNotEmpty && base.path != '/') ||
        base.hasQuery ||
        base.hasFragment ||
        base.toString() != serverBaseUrl) {
      throw const FormatException();
    }
    return base.replace(path: '/mobile/envelopes', query: null, fragment: null);
  }

  static ({String nonce, String ciphertext}) _responseOuter(List<int> body) {
    if (body.length > _maximumResponseBytes) throw const FormatException();
    final Object? decoded = jsonDecode(utf8.decode(body, allowMalformed: false));
    if (decoded is! Map<Object?, Object?> ||
        decoded.length != 3 ||
        decoded['version'] != 1 ||
        decoded['nonce'] is! String ||
        decoded['ciphertext'] is! String) {
      throw const FormatException();
    }
    return (nonce: decoded['nonce'] as String, ciphertext: decoded['ciphertext'] as String);
  }
}
