import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_lifecycle_bloc.dart';

void main() {
  const PaymentLifecycleScope scope = PaymentLifecycleScope(
    tenantId: 'tenant-001',
    deviceId: 'device-001',
  );
  final DateTime now = DateTime.utc(2026, 8, 30, 10);

  test('publishes loading then an offline state without exposing credentials', () async {
    final PaymentLifecycleBloc bloc = PaymentLifecycleBloc(
      lifecycle: _OfflineLifecycle(),
      now: () => now,
    );

    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PaymentLifecycleLoading>(),
        isA<PaymentLifecycleOffline>(),
      ]),
    );

    bloc.add(const PaymentLifecycleSyncRequested(scope));
    await states;
    await bloc.close();
  });

  test('drops retry intent while a sync is still running', () async {
    final Completer<PaymentLifecycleResult> response = Completer<PaymentLifecycleResult>();
    final _DeferredLifecycle lifecycle = _DeferredLifecycle(response);
    final PaymentLifecycleBloc bloc = PaymentLifecycleBloc(
      lifecycle: lifecycle,
      now: () => now,
    );
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PaymentLifecycleLoading>(),
        isA<PaymentLifecycleCompleted>(),
      ]),
    );

    bloc
      ..add(const PaymentLifecycleSyncRequested(scope))
      ..add(const PaymentLifecycleRetryRequested(scope));
    await Future<void>.delayed(Duration.zero);
    expect(lifecycle.calls, 1);
    response.complete(const PaymentLifecycleResult.completed());
    await states;
    await bloc.close();
  });

  test('maps a typed lifecycle failure to the failure state', () async {
    final PaymentLifecycleBloc bloc = PaymentLifecycleBloc(
      lifecycle: _TypedFailureLifecycle(),
      now: () => now,
    );
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PaymentLifecycleLoading>(),
        isA<PaymentLifecycleFailure>(),
      ]),
    );

    bloc.add(const PaymentLifecycleSyncRequested(scope));
    await states;
    await bloc.close();
  });

  test('reports unexpected errors without converting them to failure state', () async {
    final Completer<Object> reported = Completer<Object>();
    late PaymentLifecycleBloc bloc;

    await runZonedGuarded(() async {
      bloc = PaymentLifecycleBloc(lifecycle: _UnexpectedFailureLifecycle(), now: () => now);
      final Future<void> states = expectLater(
        bloc.stream,
        emits(isA<PaymentLifecycleLoading>()),
      );
      bloc.add(const PaymentLifecycleSyncRequested(scope));
      await states;
      await reported.future;
    }, (Object error, StackTrace stackTrace) {
      if (!reported.isCompleted) reported.complete(error);
    });

    expect(await reported.future, isA<StateError>());
    expect(bloc.state, isA<PaymentLifecycleLoading>());
    await bloc.close();
  });
}

final class _OfflineLifecycle implements PaymentLifecycle {
  @override
  Future<PaymentLifecycleResult> sync(
    PaymentLifecycleScope scope,
    DateTime now,
  ) async => const PaymentLifecycleResult.offline();
}

final class _DeferredLifecycle implements PaymentLifecycle {
  _DeferredLifecycle(this.response);

  final Completer<PaymentLifecycleResult> response;
  int calls = 0;

  @override
  Future<PaymentLifecycleResult> sync(
    PaymentLifecycleScope scope,
    DateTime now,
  ) {
    calls++;
    return response.future;
  }
}

final class _TypedFailureLifecycle implements PaymentLifecycle {
  @override
  Future<PaymentLifecycleResult> sync(PaymentLifecycleScope scope, DateTime now) =>
      Future<PaymentLifecycleResult>.error(const PaymentLifecycleException());
}

final class _UnexpectedFailureLifecycle implements PaymentLifecycle {
  @override
  Future<PaymentLifecycleResult> sync(PaymentLifecycleScope scope, DateTime now) =>
      Future<PaymentLifecycleResult>.error(StateError('unexpected'));
}
