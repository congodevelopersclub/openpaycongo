import 'package:flutter/services.dart';

enum PairingActivationConsumeResult { activated, recoveryRequired }

/// Narrow native activation sink. It accepts encrypted server bytes and returns
/// only a redacted outcome; directional keys and credential plaintext never
/// cross this boundary back into Dart.
final class PlatformPairingActivationVault {
  const PlatformPairingActivationVault()
    : _channel = const MethodChannel('openpaycongo/pairing_activation');

  final MethodChannel _channel;

  Future<PairingActivationConsumeResult> consume({
    required Uint8List intentId,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    final Uint8List intent = Uint8List.fromList(intentId);
    final Uint8List copiedNonce = Uint8List.fromList(nonce);
    final Uint8List copiedCiphertext = Uint8List.fromList(ciphertext);
    try {
      if (intent.length != 16 || copiedNonce.length != 24) {
        return PairingActivationConsumeResult.recoveryRequired;
      }
      final String? result = await _channel.invokeMethod<String>(
        'consume',
        <String, Uint8List>{
          'intent_id': intent,
          'nonce': copiedNonce,
          'ciphertext': copiedCiphertext,
        },
      );
      return result == 'activated'
          ? PairingActivationConsumeResult.activated
          : PairingActivationConsumeResult.recoveryRequired;
    } on PlatformException {
      return PairingActivationConsumeResult.recoveryRequired;
    } finally {
      intent.fillRange(0, intent.length, 0);
      copiedNonce.fillRange(0, copiedNonce.length, 0);
      copiedCiphertext.fillRange(0, copiedCiphertext.length, 0);
    }
  }
}
