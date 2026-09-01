import 'package:flutter/services.dart';

import '../presentation/pairing_protocol_bloc.dart';
import '../presentation/pairing_v2_crypto.dart';

/// Android Keystore-backed directional pairing-key vault.
///
/// Native code copies, encrypts, and atomically replaces the record. This
/// adapter never retains the keys after its channel operation completes.
final class PlatformPairingDirectionalKeyVault
    implements PairingDirectionalKeyVault {
  const PlatformPairingDirectionalKeyVault()
    : _channel = const MethodChannel('openpaycongo/pairing_directional_keys');

  final MethodChannel _channel;

  @override
  Future<void> save(PairingDirectionalKeys keys) async {
    final Uint8List sendKey = Uint8List.fromList(keys.sendKey);
    final Uint8List receiveKey = Uint8List.fromList(keys.receiveKey);
    try {
      if (sendKey.length != 32 || receiveKey.length != 32) {
        throw StateError('Invalid directional pairing key material');
      }
      await _channel.invokeMethod<void>('save', <String, Uint8List>{
        'send_key': sendKey,
        'receive_key': receiveKey,
      });
    } on PlatformException {
      throw StateError('Secure pairing key storage unavailable');
    } finally {
      sendKey.fillRange(0, sendKey.length, 0);
      receiveKey.fillRange(0, receiveKey.length, 0);
    }
  }
}
