import 'package:flutter/services.dart';

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
