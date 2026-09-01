import 'dart:async';

import 'package:sodium/sodium_sumo.dart';

import '../infrastructure/platform_pairing_directional_key_vault.dart';
import '../infrastructure/platform_pairing_qr_scanner.dart';
import '../infrastructure/platform_pairing_qr_trust_store.dart';
import 'pairing_protocol_bloc.dart';
import 'pairing_qr_bloc.dart';
import 'pairing_v2_completion.dart';

/// Production-only pairing composition. Native crypto starts before a scanner
/// is made available, so verified QR material cannot enter an unready flow.
final class PairingRuntime {
  PairingRuntime._({required this.qr, required this.protocol});

  final PairingQrBloc qr;
  final PairingProtocolBloc protocol;

  static Future<PairingRuntime> create({
    Future<SodiumSumo> Function()? initializeSodium,
  }) async {
    final FutureOr<SodiumSumo> Function() initialize =
        initializeSodium ?? SodiumSumoInit.init;
    final SodiumSumo sodium = await initialize();
    final PairingProtocolBloc protocol = PairingProtocolBloc(
      protocol: PairingV2CompletionProtocol(
        sodium: sodium,
        transport: DartIoPairingV2CompletionTransport(),
      ),
      vault: const PlatformPairingDirectionalKeyVault(),
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
