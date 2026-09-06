import 'dart:typed_data';

/// Routing-safe ciphertext returned by the paired mobile vault. No key, bearer,
/// or plaintext crosses this boundary.
final class MobileRequestEnvelope {
  const MobileRequestEnvelope({
    required this.version,
    required this.serverBaseUrl,
    required this.installationId,
    required this.counter,
    required this.nonce,
    required this.ciphertext,
  });

  final int version;
  final String serverBaseUrl;
  final String installationId;
  final String counter;
  final String nonce;
  final String ciphertext;
}

enum MobileEnvelopeResponseOutcome { recorded, replayed, conflict }

/// The data layer requires only native sealing and authenticated outcomes.
abstract interface class MobileEnvelopeSealer {
  Future<MobileRequestEnvelope> sealDeposit(Uint8List payload);

  /// Seals evidence only after the protected review screen has obtained the
  /// user's explicit consent. Implementations that predate this protocol
  /// operation fail closed rather than silently falling back to plain HTTP.
  Future<MobileRequestEnvelope> sealOperatorSmsInterpretationRequest(
    Uint8List payload,
  ) => throw UnsupportedError('operator_sms_interpretation_request_unavailable');

  Future<MobileEnvelopeResponseOutcome> openDepositResponse({
    required MobileRequestEnvelope request,
    required int status,
    required String nonce,
    required String ciphertext,
  });

  Future<MobileEnvelopeResponseOutcome> openOperatorSmsInterpretationResponse({
    required MobileRequestEnvelope request,
    required int status,
    required String nonce,
    required String ciphertext,
  }) => openDepositResponse(
    request: request,
    status: status,
    nonce: nonce,
    ciphertext: ciphertext,
  );
}
