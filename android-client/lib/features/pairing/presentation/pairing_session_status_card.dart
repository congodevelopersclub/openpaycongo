import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'pairing_session_bloc.dart';
final class PairingSessionStatusCard extends StatelessWidget {
  const PairingSessionStatusCard({super.key});
  @override Widget build(BuildContext context) => BlocBuilder<PairingSessionBloc, PairingSessionState>(builder: (context, state) => Card(child: Padding(padding: const EdgeInsets.all(16), child: switch (state) {
    PairingSessionIdle() => const Text('Pairing has not started'),
    PairingSessionLoading() => const Text('Pairing in progress'),
    PairingSessionPending() => const Text('Pairing awaits confirmation'),
    PairingSessionActive() => const Text('Pairing is active'),
    PairingSessionOffline() => const Text('Pairing is offline'),
    PairingSessionRecoveryRequired() => const Text('Pairing recovery required'),
    PairingSessionExpired() => const Text('Pairing expired'),
  })));
}
