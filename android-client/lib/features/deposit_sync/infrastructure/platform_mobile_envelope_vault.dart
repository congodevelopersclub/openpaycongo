import 'package:flutter/services.dart';

/// Routing-safe ciphertext returned by Android. No key, bearer, or plaintext
/// reaches Dart from this boundary.
final class MobileRequestEnvelope {
  const MobileRequestEnvelope({
    required this.version,
    required this.installationId,
    required this.counter,
    required this.nonce,
    required this.ciphertext,
  });

  final int version;
  final String installationId;
  final String counter;
  final String nonce;
  final String ciphertext;
}

/// Native envelope boundary. BLoCs receive only redacted success/failure state.
final class PlatformMobileEnvelopeVault {
  const PlatformMobileEnvelopeVault()
    : _channel = const MethodChannel('openpaycongo/mobile_envelope');

  final MethodChannel _channel;

  Future<MobileRequestEnvelope> sealDeposit(Uint8List payload) async {
    try {
      final Map<Object?, Object?>? value = await _channel.invokeMapMethod<Object?, Object?>(
        'seal',
        <String, Object>{'operation': 'deposit', 'payload': payload},
      );
      if (value == null) {
        throw const FormatException();
      }
      final int? version = value['version'] as int?;
      final String? installationId = value['installation_id'] as String?;
      final String? counter = value['counter'] as String?;
      final String? nonce = value['nonce'] as String?;
      final String? ciphertext = value['ciphertext'] as String?;
      if (version != 1 || installationId == null || counter == null || nonce == null || ciphertext == null) {
        throw const FormatException();
      }
      return MobileRequestEnvelope(
        version: version!,
        installationId: installationId,
        counter: counter,
        nonce: nonce,
        ciphertext: ciphertext,
      );
    } on PlatformException {
      throw StateError('Mobile envelope unavailable');
    } on FormatException {
      throw StateError('Mobile envelope unavailable');
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }
}
