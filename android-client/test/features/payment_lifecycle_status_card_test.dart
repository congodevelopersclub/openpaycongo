import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_lifecycle_bloc.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_lifecycle_status_card.dart';

void main() {
  const PaymentLifecycleScope scope = PaymentLifecycleScope(
    tenantId: 'tenant-001',
    deviceId: 'device-001',
  );

  testWidgets('renders loading and offline recovery from BLoC state', (WidgetTester tester) async {
    final Completer<PaymentLifecycleResult> response = Completer<PaymentLifecycleResult>();
    final PaymentLifecycleBloc bloc = PaymentLifecycleBloc(
      lifecycle: _DeferredLifecycle(response),
      now: () => DateTime.utc(2026, 8, 30, 10),
    );
    addTearDown(bloc.close);

    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<PaymentLifecycleBloc>.value(
        value: bloc,
        child: const PaymentLifecycleStatusCard(),
      ),
    ));

    bloc.add(const PaymentLifecycleSyncRequested(scope));
    await tester.pump();
    expect(find.text('Payment sync in progress'), findsOneWidget);

    response.complete(const PaymentLifecycleResult.offline());
    await tester.pump();
    await tester.pump();
    expect(find.text('Payment sync is offline'), findsOneWidget);
    expect(find.text('Retry sync'), findsOneWidget);
  });
}

final class _DeferredLifecycle implements PaymentLifecycle {
  const _DeferredLifecycle(this.response);

  final Completer<PaymentLifecycleResult> response;

  @override
  Future<PaymentLifecycleResult> sync(
    PaymentLifecycleScope scope,
    DateTime now,
  ) => response.future;
}
