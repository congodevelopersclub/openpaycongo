import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'payment_lifecycle_bloc.dart';

/// Declarative surface for the durable outbox lifecycle. It contains no
/// credential, transport, persistence, or payment-policy decisions.
final class PaymentLifecycleStatusCard extends StatelessWidget {
  const PaymentLifecycleStatusCard({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<
    PaymentLifecycleBloc,
    PaymentLifecycleState
  >(
    builder: (BuildContext context, PaymentLifecycleState state) => switch (state) {
      PaymentLifecycleIdle() => const SizedBox.shrink(),
      PaymentLifecycleLoading() => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Payment sync in progress'),
        ),
      ),
      PaymentLifecycleCompleted() => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Payment sync completed'),
        ),
      ),
      PaymentLifecyclePartial(:final PaymentLifecycleScope scope) => _RetryCard(
        message: 'Payment sync is pending retry',
        scope: scope,
      ),
      PaymentLifecycleOffline(:final PaymentLifecycleScope scope) => _RetryCard(
        message: 'Payment sync is offline',
        scope: scope,
      ),
      PaymentLifecycleCancelled(:final PaymentLifecycleScope scope) => _RetryCard(
        message: 'Payment sync was cancelled',
        scope: scope,
      ),
      PaymentLifecycleFailure(:final PaymentLifecycleScope scope) => _RetryCard(
        message: 'Payment sync failed',
        scope: scope,
      ),
    },
  );
}

final class _RetryCard extends StatelessWidget {
  const _RetryCard({required this.message, required this.scope});

  final String message;
  final PaymentLifecycleScope scope;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => context.read<PaymentLifecycleBloc>().add(
              PaymentLifecycleRetryRequested(scope),
            ),
            child: const Text('Retry sync'),
          ),
        ],
      ),
    ),
  );
}
