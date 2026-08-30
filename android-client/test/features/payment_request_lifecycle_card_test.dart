import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_request_lifecycle_bloc.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_request_lifecycle_card.dart';

void main() {
  testWidgets('renders failure and translates retry tap into a BLoC event', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _RetryServer server = _RetryServer();
    final PaymentRequestLifecycleBloc bloc = PaymentRequestLifecycleBloc(
      store: store,
      server: server,
      now: () => DateTime.utc(2026, 8, 30, 10),
    );
    addTearDown(bloc.close);
    final PaymentRequest request = PaymentRequest(
      requestId: 'request-005',
      expiresAt: DateTime.utc(2026, 8, 30, 11),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<PaymentRequestLifecycleBloc>.value(
          value: bloc,
          child: const PaymentRequestLifecycleCard(),
        ),
      ),
    );
    bloc.add(PaymentRequestSubmitted(request));
    await tester.pump();
    await tester.pump();
    expect(find.text('Payment request could not be updated'), findsOneWidget);

    await tester.tap(find.text('Retry payment request'));
    await server.retryEntered.future;
    await tester.pump();
    expect(find.text('Retrying payment request'), findsOneWidget);
    server.retryResult.complete(const PaymentRequestServerResult.paid());
    await tester.pump();
    await tester.pump();
    expect(find.text('Payment request is paid'), findsOneWidget);
  });
}

final class _Store implements PaymentRequestLifecycleStore {
  PaymentRequestSnapshot? value;

  @override
  Future<PaymentRequestSnapshot?> load(String requestId) async =>
      value?.request.requestId == requestId ? value : null;

  @override
  Future<void> save(PaymentRequestSnapshot snapshot) async {
    value = snapshot;
  }
}

final class _RetryServer implements PaymentRequestServer {
  final Completer<void> retryEntered = Completer<void>();
  final Completer<PaymentRequestServerResult> retryResult =
      Completer<PaymentRequestServerResult>();
  int calls = 0;

  @override
  Future<PaymentRequestServerResult> submit(PaymentRequest request) {
    calls++;
    if (calls == 1) {
      return Future<PaymentRequestServerResult>.error(
        const PaymentRequestLifecycleException(),
      );
    }
    retryEntered.complete();
    return retryResult.future;
  }
}
