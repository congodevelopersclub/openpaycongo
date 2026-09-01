import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'pairing_protocol_bloc.dart';
import 'pairing_qr_bloc.dart';

/// Pairing status UI. It never exposes QR material, pairing keys, or secrets.
final class PairingQrVerificationScreen extends StatelessWidget {
  const PairingQrVerificationScreen({
    required this.bloc,
    this.protocol,
    super.key,
  });

  final PairingQrBloc bloc;
  final PairingProtocolBloc? protocol;

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: <BlocProvider<dynamic>>[
      BlocProvider<PairingQrBloc>.value(value: bloc),
      if (protocol case final PairingProtocolBloc value)
        BlocProvider<PairingProtocolBloc>.value(value: value),
    ],
    child: _PairingQrVerificationBody(protocol: protocol),
  );
}

final class _PairingQrVerificationBody extends StatelessWidget {
  const _PairingQrVerificationBody({this.protocol});

  final PairingProtocolBloc? protocol;

  @override
  Widget build(BuildContext context) {
    if (protocol == null) {
      return BlocBuilder<PairingQrBloc, PairingQrState>(
        builder: (BuildContext context, PairingQrState state) =>
            _Scaffold(qr: state, protocol: null),
      );
    }
    return BlocBuilder<PairingProtocolBloc, PairingProtocolState>(
      builder: (BuildContext context, PairingProtocolState protocolState) =>
          BlocBuilder<PairingQrBloc, PairingQrState>(
            builder: (BuildContext context, PairingQrState qrState) =>
                _Scaffold(qr: qrState, protocol: protocolState),
          ),
    );
  }
}

final class _Scaffold extends StatelessWidget {
  const _Scaffold({required this.qr, required this.protocol});

  final PairingQrState qr;
  final PairingProtocolState? protocol;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Verify pairing QR')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Pair a device',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Scan a QR code shown by an authenticated administrator. '
              'A verified QR starts encrypted pairing. Device access still '
              'requires matching code and mandatory administrator confirmation.',
            ),
            const SizedBox(height: 24),
            _VerificationStatus(qr: qr, protocol: protocol),
            const Spacer(),
            Semantics(
              label: 'Scan pairing QR code',
              button: true,
              child: FilledButton.icon(
                onPressed:
                    qr is PairingQrScanning ||
                        protocol is PairingProtocolEstablishing ||
                        protocol is PairingProtocolAwaitingConfirmation
                    ? null
                    : () => context.read<PairingQrBloc>().add(
                        const PairingQrScanRequested(),
                      ),
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
  );
}

final class _VerificationStatus extends StatelessWidget {
  const _VerificationStatus({required this.qr, required this.protocol});

  final PairingQrState qr;
  final PairingProtocolState? protocol;

  @override
  Widget build(BuildContext context) {
    if (protocol case PairingProtocolAwaitingConfirmation(:final sas)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _StatusCard(
            color: Theme.of(context).colorScheme.secondaryContainer,
            message:
                'Encrypted pairing response verified. Compare six-digit code $sas with administrator. Administrator confirmation is mandatory. Device is not active.',
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => context.read<PairingProtocolBloc>().add(
              const PairingActivationRequested(),
            ),
            child: const Text('Check activation after administrator confirms'),
          ),
        ],
      );
    }
    if (protocol is PairingProtocolActivating) {
      return const Row(
        children: <Widget>[
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator()),
          SizedBox(width: 12),
          Text('Checking pairing activation…'),
        ],
      );
    }
    if (protocol is PairingProtocolActivated) {
      return _StatusCard(
        color: Theme.of(context).colorScheme.primaryContainer,
        message: 'Pairing activated.',
      );
    }
    if (protocol is PairingProtocolRecoveryRequired) {
      return _StatusCard(
        color: Theme.of(context).colorScheme.errorContainer,
        message: 'Encrypted pairing could not finish. No device was paired. Start again with a new administrator QR code.',
      );
    }
    return switch (qr) {
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
        message: 'QR verified. Pairing is not complete; keep this device available for the required administrator confirmation.',
      ),
      PairingQrRejected() => _StatusCard(
        color: Theme.of(context).colorScheme.errorContainer,
        message: 'This QR code cannot be verified.',
      ),
      PairingQrScannerUnavailable() => _StatusCard(
        color: Theme.of(context).colorScheme.errorContainer,
        message: 'QR scanning is unavailable. Try again when camera access is available.',
      ),
    };
  }
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
