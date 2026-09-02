import 'dart:convert';
import 'package:flutter/services.dart';

import '../presentation/pairing_protocol_bloc.dart';
import '../presentation/pairing_v2_completion.dart';
import '../presentation/pairing_v2_crypto.dart';

/// Android-only pairing crypto bridge. It transfers the one-time QR secret to
/// native code once, then exposes only public request fields and a verified SAS.
/// Directional keys never enter this MethodChannel or Dart heap.
final class PlatformPairingV2Crypto implements PairingV2CryptoPort {
  PlatformPairingV2Crypto()
    : _channel = const MethodChannel('openpaycongo/pairing_completion');

  final MethodChannel _channel;
  String? _intentId;

  @override
  Future<PairingV2Request> begin(PairingV2QrCredential credential) async {
    final Uint8List pairingSecret = credential.takePairingSecret();
    try {
      final Map<Object?, Object?>? value = await _channel.invokeMapMethod<Object?, Object?>(
        'begin',
        <String, Object>{
          'intent_id': credential.intentId,
          'server_public_key': credential.serverPublicKey,
          'canonical_server_base_url': credential.canonicalServerBaseUrl,
          'pairing_secret': pairingSecret,
        },
      );
      const Set<String> expectedFields = <String>{
        'intent_id',
        'client_public_key',
        'nonce',
        'ciphertext',
      };
      if (value == null ||
          value.length != expectedFields.length ||
          value.keys.any((Object? key) => key is! String || !expectedFields.contains(key))) {
        throw const FormatException();
      }
      final String? intentId = value['intent_id'] as String?;
      final String? clientPublicKey = value['client_public_key'] as String?;
      final String? nonce = value['nonce'] as String?;
      final String? ciphertext = value['ciphertext'] as String?;
      if (intentId != credential.intentId ||
          clientPublicKey == null ||
          nonce == null ||
          ciphertext == null) {
        throw const FormatException();
      }
      final PairingV2Request request = PairingV2Request(
        intentId: intentId!,
        clientPublicKey: clientPublicKey,
        nonce: nonce,
        ciphertext: ciphertext,
      );
      _intentId = request.intentId;
      return request;
    } on PlatformException {
      throw StateError('Pairing completion is unavailable');
    } on FormatException {
      throw StateError('Pairing completion is unavailable');
    } finally {
      pairingSecret.fillRange(0, pairingSecret.length, 0);
    }
  }

  @override
  Future<String> accept(PairingV2Response response) async {
    final String? intentId = _intentId;
    if (intentId == null) throw StateError('Pairing completion is unavailable');
    try {
      final String? sas = await _channel.invokeMethod<String>('accept', <String, String>{
        'intent_id': intentId,
        'nonce': response.nonce,
        'ciphertext': response.ciphertext,
      });
      if (sas == null || !RegExp(r'^[0-9]{6}$').hasMatch(sas)) {
        throw const FormatException();
      }
      _intentId = null;
      return sas;
    } on PlatformException {
      throw StateError('Pairing completion is unavailable');
    } on FormatException {
      throw StateError('Pairing completion is unavailable');
    }
  }

  @override
  Future<void> dispose() async {
    _intentId = null;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Nothing from the native session reaches Dart; next begin replaces it.
    }
  }
}

/// Restores only native-authenticated, post-confirmation routing material.
/// Native vault owns both directional keys and the pinned server origin.
final class PlatformPairingConfirmedExchangeRecovery implements PairingRecoveryPort {
  const PlatformPairingConfirmedExchangeRecovery()
    : _channel = const MethodChannel('openpaycongo/pairing_completion');

  final MethodChannel _channel;

  @override
  Future<PairingRecoveredMaterial?> restore() async {
    try {
      final Map<Object?, Object?>? value = await _channel.invokeMapMethod<Object?, Object?>(
        'restoreConfirmed',
      );
      if (value == null) return null;
      const Set<String> fields = <String>{'sas', 'completion_endpoint', 'intent_id'};
      if (value.length != fields.length ||
          value.keys.any((Object? key) => key is! String || !fields.contains(key))) {
        throw const FormatException();
      }
      final String? sas = value['sas'] as String?;
      final String? endpointValue = value['completion_endpoint'] as String?;
      final String? intentValue = value['intent_id'] as String?;
      if (sas == null ||
          endpointValue == null ||
          intentValue == null ||
          !RegExp(r'^[0-9]{6}$').hasMatch(sas)) {
        throw const FormatException();
      }
      final Uri endpoint = Uri.parse(endpointValue);
      if (endpoint.scheme != 'https' ||
          !endpoint.hasAuthority ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.path != '/v1/pairing/complete' ||
          endpoint.hasQuery ||
          endpoint.hasFragment) {
        throw const FormatException();
      }
      final Uint8List intent = Uint8List.fromList(base64Url.decode(base64Url.normalize(intentValue)));
      try {
        if (intent.length != 16 || base64UrlEncode(intent).replaceAll('=', '') != intentValue) {
          throw const FormatException();
        }
        return PairingRecoveredMaterial(
          serverSas: sas,
          activationRequest: PairingV2ActivationRequest(endpoint, intent),
        );
      } finally {
        intent.fillRange(0, intent.length, 0);
      }
    } on PlatformException {
      throw StateError('Pairing recovery is unavailable');
    } on FormatException {
      throw StateError('Pairing recovery is unavailable');
    }
  }
}
