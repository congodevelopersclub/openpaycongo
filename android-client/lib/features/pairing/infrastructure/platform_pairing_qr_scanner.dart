import 'package:flutter/services.dart';

import '../presentation/pairing_qr_bloc.dart';

/// Native camera scanner boundary. The raw result is returned only to the
/// validator BLoC and is never logged or stored by this adapter.
final class PlatformPairingQrScanner implements PairingQrScanner {
  const PlatformPairingQrScanner()
    : _channel = const MethodChannel('openpaycongo/pairing_qr_scanner');

  final MethodChannel _channel;

  @override
  Future<String?> scan() async {
    try {
      final String? value = await _channel.invokeMethod<String>('scan');
      if (value != null && value.length > 4096) {
        throw StateError('Invalid QR scanner result');
      }
      return value;
    } on PlatformException {
      throw StateError('QR scanner unavailable');
    }
  }
}
