import 'package:flutter/material.dart';
import 'pairing_qr_bloc.dart';
import 'pairing_qr_verification_screen.dart';

/// Entry point from the protected product route into QR verification.
final class PairingQrVerificationCard extends StatelessWidget {
  const PairingQrVerificationCard({required this.bloc, super.key});

  final PairingQrBloc bloc;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Device pairing',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Verify an administrator-provided QR before any later pairing step.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PairingQrVerificationScreen(bloc: bloc),
              ),
            ),
            child: const Text('Verify pairing QR'),
          ),
        ],
      ),
    ),
  );
}
