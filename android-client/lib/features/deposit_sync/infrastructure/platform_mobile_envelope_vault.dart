import 'package:flutter/services.dart';

import '../data/mobile_envelope_sealer.dart';

/// Native envelope boundary. BLoCs receive only redacted success/failure state.
final class PlatformMobileEnvelopeVault implements MobileEnvelopeSealer {
  const PlatformMobileEnvelopeVault()
    : _channel = const MethodChannel('openpaycongo/mobile_envelope');

  final MethodChannel _channel;

  @override
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
      final String? serverBaseUrl = value['server_base_url'] as String?;
      final String? installationId = value['installation_id'] as String?;
      final String? counter = value['counter'] as String?;
      final String? nonce = value['nonce'] as String?;
      final String? ciphertext = value['ciphertext'] as String?;
      if (version != 1 || serverBaseUrl == null || installationId == null || counter == null || nonce == null || ciphertext == null) {
        throw const FormatException();
      }
      return MobileRequestEnvelope(
        version: version!,
        serverBaseUrl: serverBaseUrl,
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

  @override
  Future<MobileEnvelopeResponseOutcome> openDepositResponse({
    required MobileRequestEnvelope request,
    required int status,
    required String nonce,
    required String ciphertext,
  }) async {
    try {
      final String? outcome = await _channel.invokeMethod<String>(
        'open',
        <String, Object>{
          'installation_id': request.installationId,
          'counter': request.counter,
          'status': status,
          'nonce': nonce,
          'ciphertext': ciphertext,
        },
      );
      return switch (outcome) {
        'recorded' => MobileEnvelopeResponseOutcome.recorded,
        'replayed' => MobileEnvelopeResponseOutcome.replayed,
        'conflict' => MobileEnvelopeResponseOutcome.conflict,
        _ => throw const FormatException(),
      };
    } on PlatformException {
      throw StateError('Mobile envelope unavailable');
    } on FormatException {
      throw StateError('Mobile envelope unavailable');
    }
  }
}
