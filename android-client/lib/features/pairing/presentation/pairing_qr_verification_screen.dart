import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'pairing_qr_bloc.dart';

/// Safe, pre-enrollment QR verification only. It does not expose scanned
/// material, start completion, create credentials, or persist a trust pin.
final class PairingQrVerificationScreen extends StatelessWidget {
  const PairingQrVerificationScreen({required this.bloc, super.key});

  final PairingQrBloc bloc;

  @override
  Widget build(BuildContext context) => BlocProvider<PairingQrBloc>.value(
    value: bloc,
    child: Scaffold(
      appBar: AppBar(title: const Text('Verify pairing QR')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: BlocBuilder<PairingQrBloc, PairingQrState>(
            builder: (BuildContext context, PairingQrState state) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Pair a device',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Scan a QR code shown by an authenticated administrator. '
                  'This step checks the QR only; it does not complete pairing.',
                ),
                const SizedBox(height: 24),
                _VerificationStatus(state: state),
                const Spacer(),
                Semantics(
                  label: 'Scan pairing QR code',
                  button: true,
                  child: FilledButton.icon(
                    onPressed: state is PairingQrScanning
                        ? null
                        : () => bloc.add(const PairingQrScanRequested()),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan pairing QR'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class _VerificationStatus extends StatelessWidget {
  const _VerificationStatus({required this.state});

  final PairingQrState state;

  @override
  Widget build(BuildContext context) => switch (state) {
    PairingQrIdle() => const SizedBox.shrink(),
    PairingQrScanning() => const Row(
      children: <Widget>[
        SizedBox(width: 20, height: 20, child: CircularProgressIndicator()),
        SizedBox(width: 12),
        Text('Checking pairing QR…'),
      ],
    ),
    PairingQrAccepted() => _StatusCard(
      color: Theme.of(context).colorScheme.secondaryContainer,
      message:
          'QR verified. Pairing is not complete; keep this device available for the required administrator confirmation.',
    ),
    PairingQrRejected() => _StatusCard(
      color: Theme.of(context).colorScheme.errorContainer,
      message: 'This QR code cannot be verified.',
    ),
    PairingQrScannerUnavailable() => _StatusCard(
      color: Theme.of(context).colorScheme.errorContainer,
      message:
          'QR scanning is unavailable. Try again when camera access is available.',
    ),
  };
}

final class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.color, required this.message});

  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Card(
      color: color,
      child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
    ),
  );
}
