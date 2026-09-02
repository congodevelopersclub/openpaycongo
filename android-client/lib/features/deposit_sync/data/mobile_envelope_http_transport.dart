import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../presentation/deposit_submission_bloc.dart';
import 'mobile_deposit_http_transport.dart';
import 'mobile_envelope_sealer.dart';

/// Delivers one native-sealed provider deposit. Dart owns scheduling and HTTPS
/// routing only: its request body contains ciphertext, and native code alone
/// authenticates the encrypted server result with the paired receive key.
final class MobileEnvelopeHttpTransport implements AuthenticatedDepositTransport {
  MobileEnvelopeHttpTransport({
    required this.vault,
    required this.http,
    this.maximumResponseBytes = 1024,
    this.timeout = const Duration(seconds: 3),
  }) {
    if (maximumResponseBytes < 1 || maximumResponseBytes > 8192) {
      throw ArgumentError.value(maximumResponseBytes, 'maximumResponseBytes');
    }
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 3)) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }

  final MobileEnvelopeSealer vault;
  final MobileDepositHttpPort http;
  final int maximumResponseBytes;
  final Duration timeout;

  @override
  Future<DepositSubmissionResult> submit(ProviderDeposit deposit) async {
    final Uint8List payload = Uint8List.fromList(
      utf8.encode(jsonEncode(mobileDepositPayload(deposit))),
    );
    try {
      final MobileRequestEnvelope envelope = await vault.sealDeposit(payload);
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
          throw const DepositTransportUnavailable();
        },
      );
      final ({String nonce, String ciphertext}) outer = _responseOuter(response);
      final MobileEnvelopeResponseOutcome outcome = await vault.openDepositResponse(
        request: envelope,
        status: response.status,
        nonce: outer.nonce,
        ciphertext: outer.ciphertext,
      );
      return switch (outcome) {
        MobileEnvelopeResponseOutcome.recorded => const DepositSubmissionResult.recorded(),
        MobileEnvelopeResponseOutcome.replayed => const DepositSubmissionResult.replayed(),
        MobileEnvelopeResponseOutcome.conflict => const DepositSubmissionResult.conflict(),
      };
    } on DepositTransportUnavailable {
      rethrow;
    } on Object {
      throw const DepositTransportUnavailable();
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  Uri _endpointFor(String serverBaseUrl) {
    final Uri base = Uri.parse(serverBaseUrl);
    if (base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        (base.path.isNotEmpty && base.path != '/') ||
        base.hasQuery ||
        base.hasFragment ||
        base.toString() != serverBaseUrl) {
      throw const DepositTransportUnavailable();
    }
    return base.replace(path: '/mobile/envelopes', query: null, fragment: null);
  }

  ({String nonce, String ciphertext}) _responseOuter(MobileDepositHttpResponse response) {
    if (response.body.length > maximumResponseBytes) {
      throw const DepositTransportUnavailable();
    }
    final Object? decoded = jsonDecode(
      utf8.decode(response.body, allowMalformed: false),
    );
    if (decoded is! Map<Object?, Object?> ||
        decoded.length != 3 ||
        decoded['version'] != 1 ||
        decoded['nonce'] is! String ||
        decoded['ciphertext'] is! String) {
      throw const DepositTransportUnavailable();
    }
    return (nonce: decoded['nonce'] as String, ciphertext: decoded['ciphertext'] as String);
  }
}
