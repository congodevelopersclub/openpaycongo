import '../infrastructure/platform_pairing_activation_vault.dart';
import '../infrastructure/pairing_activation_retrieval.dart';
import '../infrastructure/platform_pairing_qr_scanner.dart';
import '../infrastructure/platform_pairing_qr_trust_store.dart';
import '../infrastructure/platform_pairing_v2_crypto.dart';
import 'pairing_protocol_bloc.dart';
import 'pairing_qr_bloc.dart';
import 'pairing_v2_completion.dart';

  /// Production-only pairing composition. Android owns directional pairing
  /// keys; Flutter receives only public request data and the verified SAS.
final class PairingRuntime {
  PairingRuntime._({required this.qr, required this.protocol});

  final PairingQrBloc qr;
  final PairingProtocolBloc protocol;

  static PairingRuntime create() {
    final PairingProtocolBloc protocol = PairingProtocolBloc(
      protocol: PairingV2CompletionProtocol(
        crypto: PlatformPairingV2Crypto(),
        transport: DartIoPairingV2CompletionTransport(),
      ),
      activation: PairingV2ActivationPort(
        consumer: PairingActivationConsumer(
          transport: DartIoPairingActivationRetrievalTransport(),
          vault: const PlatformPairingActivationVault(),
        ),
      ),
    );
    return PairingRuntime._(
      protocol: protocol,
      qr: PairingQrBloc(
        trustStore: const PlatformPairingQrTrustStore(),
        scanner: const PlatformPairingQrScanner(),
        credentialSink: PairingQrProtocolCredentialSink(protocol),
      ),
    );
  }

  Future<void> close() async {
    await qr.close();
    await protocol.close();
  }
}
