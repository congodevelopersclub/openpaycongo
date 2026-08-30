import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'pairing_enrollment_bloc.dart';

/// Presentation-only enrollment surface. It renders BLoC state and dispatches
/// intent; pairing decisions and sensitive material remain behind typed ports.
final class PairingEnrollmentStatusCard extends StatelessWidget {
  const PairingEnrollmentStatusCard({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PairingEnrollmentBloc, PairingEnrollmentState>(
        builder: (BuildContext context, PairingEnrollmentState state) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: switch (state) {
              PairingEnrollmentIdle() => const Text('No pairing enrollment'),
              PairingEnrollmentLoading() => const Text(
                'Pairing enrollment in progress',
              ),
              PairingEnrollmentPending() => const Text(
                'Pairing enrollment awaits confirmation',
              ),
              PairingEnrollmentActive() => const Text(
                'Pairing enrollment active',
              ),
              PairingEnrollmentRecoveryRequired() => _RecoveryAction(),
              PairingEnrollmentOffline() => _RetryAction(),
              PairingEnrollmentError() => _ErrorAction(),
            },
          ),
        ),
      );
}

final class _RetryAction extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      const Text('Pairing enrollment offline'),
      TextButton(
        onPressed: () => context.read<PairingEnrollmentBloc>().add(
          const PairingEnrollmentRetryRequested(),
        ),
        child: const Text('Retry pairing enrollment'),
      ),
    ],
  );
}

final class _ErrorAction extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      const Text('Pairing enrollment needs a new QR'),
      TextButton(
        onPressed: () => context.read<PairingEnrollmentBloc>().add(
          const PairingEnrollmentCancelled(),
        ),
        child: const Text('Cancel pairing enrollment'),
      ),
    ],
  );
}

final class _RecoveryAction extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      const Text('Pairing enrollment recovery required'),
      TextButton(
        onPressed: () => context.read<PairingEnrollmentBloc>().add(
          const PairingEnrollmentRecovered(),
        ),
        child: const Text('Recover pairing enrollment'),
      ),
    ],
  );
}
