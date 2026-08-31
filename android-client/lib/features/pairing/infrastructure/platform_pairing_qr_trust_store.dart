import 'package:flutter/services.dart';

import '../presentation/pairing_qr_bloc.dart';

/// Android-backed ADR-004 enrollment-signing fingerprint store.
///
/// Native code keeps encrypted record and Android Keystore key. This adapter
/// returns typed trust outcomes only; it neither authorizes first use nor
/// exposes QR material to BLoC state.
final class PlatformPairingQrTrustStore implements PairingQrTrustStore {
  const PlatformPairingQrTrustStore()
    : _channel = const MethodChannel('openpaycongo/pairing_qr_trust');

  final MethodChannel _channel;

  @override
  Future<PairingQrPinState> lookup(String fingerprint) async {
    try {
      return switch (await _channel.invokeMethod<String>('lookup', fingerprint)) {
        'matching' => const PairingQrPinState.matching(),
        'none' => const PairingQrPinState.none(),
        'conflict' => const PairingQrPinState.conflict(),
        _ => throw StateError('Invalid secure trust-store outcome'),
      };
    } on PlatformException {
      throw StateError('Secure trust storage unavailable');
    }
  }

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async {
    try {
      return switch (await _channel.invokeMethod<String>(
        'persistVerifiedFingerprint',
        fingerprint,
      )) {
        'stored' => const PairingQrPinWrite.stored(),
        'already_stored' => const PairingQrPinWrite.alreadyStored(),
        'conflict' => const PairingQrPinWrite.conflict(),
        _ => throw StateError('Invalid secure trust-store outcome'),
      };
    } on PlatformException {
      throw StateError('Secure trust storage unavailable');
    }
  }
}
