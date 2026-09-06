import 'package:flutter/services.dart';

import '../domain/payment_ingestion.dart';

/// Invokes the Android-only, on-device Gemma 4 runtime. The SMS body crosses
/// only a local platform channel and is never sent to a server.
final class PlatformGemma4ProposalPort implements GemmaProposalPort {
  const PlatformGemma4ProposalPort([
    this._channel = const MethodChannel('openpaycongo/sms_gateway'),
  ]);

  static final RegExp _senderPattern = RegExp(
    r'^(?:\+[1-9][0-9]{7,14}|[A-Z0-9]{3,11})$',
  );
  final MethodChannel _channel;

  @override
  Future<String> proposeJson(SmsEnvelope envelope, Duration timeout) async {
    if (!_senderPattern.hasMatch(envelope.sender.value) ||
        envelope.body.length > SmsEnvelope.maxBytes ||
        timeout <= Duration.zero) {
      throw const FormatException('invalid_gemma4_payment_request');
    }
    final String? response = await _channel.invokeMethod<String>(
      'proposeGemma4Payment',
      <String, String>{'sender': envelope.sender.value, 'body': envelope.body},
    );
    if (response == null || response.length > 2048) {
      throw const FormatException('invalid_gemma4_payment_response');
    }
    return response;
  }
}
