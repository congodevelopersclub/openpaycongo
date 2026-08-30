import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'payment_request_lifecycle_bloc.dart';

/// Declarative request-status surface. All transition, server, and persistence
/// decisions remain in [PaymentRequestLifecycleBloc].
final class PaymentRequestLifecycleCard extends StatelessWidget {
  const PaymentRequestLifecycleCard({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PaymentRequestLifecycleBloc, PaymentRequestLifecycleState>(
        builder: (BuildContext context, PaymentRequestLifecycleState state) =>
            switch (state) {
              PaymentRequestIdle() => const SizedBox.shrink(),
              PaymentRequestPending(:final retryableRequests) => _RequestCard(
                'Payment request is pending',
                retryableRequests,
              ),
              PaymentRequestPaid(:final retryableRequests) => _RequestCard(
                'Payment request is paid',
                retryableRequests,
              ),
              PaymentRequestExpired(:final retryableRequests) => _RequestCard(
                'Payment request expired',
                retryableRequests,
              ),
              PaymentRequestRetrying(:final retryableRequests) => _RequestCard(
                'Retrying payment request',
                retryableRequests,
              ),
              PaymentRequestFailure(
                retryable: false,
                :final retryableRequests,
              ) =>
                _RequestCard(
                  'Payment request conflicts with saved state',
                  retryableRequests,
                ),
              PaymentRequestFailure(
                :final PaymentRequest request,
                :final retryableRequests,
              ) =>
                _RetryCards(
                  retryableRequests.isEmpty
                      ? <PaymentRequest>[request]
                      : retryableRequests,
                ),
            },
      );
}

final class _RequestCard extends StatelessWidget {
  const _RequestCard(this.message, this.retryableRequests);

  final String message;
  final List<PaymentRequest> retryableRequests;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Card(
        child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
      ),
      if (retryableRequests.isNotEmpty) _RetryCards(retryableRequests),
    ],
  );
}

final class _RetryCards extends StatelessWidget {
  const _RetryCards(this.requests);

  final List<PaymentRequest> requests;

  @override
  Widget build(BuildContext context) => Column(
    children: requests
        .map(
          (PaymentRequest request) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Payment request could not be updated'),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context
                        .read<PaymentRequestLifecycleBloc>()
                        .add(PaymentRequestRetryRequested(request)),
                    child: const Text('Retry payment request'),
                  ),
                ],
              ),
            ),
          ),
        )
        .toList(),
  );
}
