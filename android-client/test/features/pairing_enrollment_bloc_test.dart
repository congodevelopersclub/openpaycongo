import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_enrollment_bloc.dart';

void main() {
  test('persists a pending enrollment and recovers it after restart', () async {
    final _Store store = _Store();
    final _Telemetry telemetry = _Telemetry();
    final PairingEnrollment enrollment = PairingEnrollment(
      phase: PairingEnrollmentPhase.pendingConfirmation,
      updatedAt: DateTime.utc(2026, 8, 30),
    );
    final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
      store: store,
      transport: _Transport(enrollment),
      telemetry: telemetry,
    );
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentPending>(),
      ]),
    );

    bloc.add(const PairingEnrollmentStarted());

    await states;
    expect(store.value, same(enrollment));
    await bloc.close();

    final PairingEnrollmentBloc restarted = PairingEnrollmentBloc(
      store: store,
      transport: _Transport(enrollment),
      telemetry: telemetry,
    );
    final Future<void> restored = expectLater(
      restarted.stream,
      emitsInOrder(<Matcher>[
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentPending>(),
      ]),
    );

    restarted.add(const PairingEnrollmentRecovered());

    await restored;
    expect(telemetry.signals, contains(PairingEnrollmentTelemetry.recovered));
    await restarted.close();
  });

  test(
    'cancel wins over an in-flight enrollment and clears durable state',
    () async {
      final Completer<PairingEnrollment> begin = Completer<PairingEnrollment>();
      final _Store store = _Store();
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: store,
        transport: _DeferredTransport(begin),
        telemetry: _Telemetry(),
      );
      bloc.add(const PairingEnrollmentStarted());
      await Future<void>.delayed(Duration.zero);
      final Future<PairingEnrollmentState> idle = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentIdle,
      );
      bloc.add(const PairingEnrollmentCancelled());
      await idle;
      begin.complete(_pending());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<PairingEnrollmentIdle>());
      expect(store.value, isNull);
      await bloc.close();
    },
  );

  test('timeout becomes offline and retry reaches active enrollment', () async {
    final _Store store = _Store();
    final _RetryTransport transport = _RetryTransport();
    final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
      store: store,
      transport: transport,
      telemetry: _Telemetry(),
    );
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentOffline>(),
        isA<PairingEnrollmentLoading>(),
        isA<PairingEnrollmentActive>(),
      ]),
    );

    bloc.add(const PairingEnrollmentStarted());
    await bloc.stream.firstWhere(
      (PairingEnrollmentState state) => state is PairingEnrollmentOffline,
    );
    bloc.add(const PairingEnrollmentRetryRequested());

    await states;
    expect(transport.beginCalls, 2);
    await bloc.close();
  });

  test(
    'typed protocol failure emits error and recovery without state is empty',
    () async {
      final _Telemetry telemetry = _Telemetry();
      final PairingEnrollmentBloc bloc = PairingEnrollmentBloc(
        store: _Store(),
        transport: const _ProtocolFailureTransport(),
        telemetry: telemetry,
      );
      final Future<PairingEnrollmentState> error = bloc.stream.firstWhere(
        (PairingEnrollmentState state) => state is PairingEnrollmentError,
      );
      bloc.add(const PairingEnrollmentStarted());
      await error;
      bloc.add(const PairingEnrollmentRecovered());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<PairingEnrollmentIdle>());
      expect(telemetry.signals, contains(PairingEnrollmentTelemetry.error));
      await bloc.close();
    },
  );

  for (final PairingEnrollmentEvent event in <PairingEnrollmentEvent>[
    const PairingEnrollmentRetryRequested(),
    const PairingEnrollmentRecovered(),
  ]) {
    test('unexpected load error reaches the observer for $event', () async {
      final _RecordingObserver observer = _RecordingObserver();
      final BlocObserver previous = Bloc.observer;
      Bloc.observer = observer;
      addTearDown(() => Bloc.observer = previous);
      final Completer<Object> uncaught = Completer<Object>();
      late final PairingEnrollmentBloc bloc;
      runZonedGuarded(() {
        bloc = PairingEnrollmentBloc(
          store: const _UnexpectedLoadStore(),
          transport: _Transport(_pending()),
          telemetry: _Telemetry(),
        );
        bloc.add(event);
      }, (Object error, StackTrace _) => uncaught.complete(error));

      await observer.error;
      expect(observer.observed, isA<StateError>());
      expect(await uncaught.future, isA<StateError>());
      await bloc.close();
    });
  }
}

PairingEnrollment _pending() => PairingEnrollment(
  phase: PairingEnrollmentPhase.pendingConfirmation,
  updatedAt: DateTime.utc(2026, 8, 30),
);

final class _Store implements PairingEnrollmentStore {
  PairingEnrollment? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<PairingEnrollment?> load() async => value;

  @override
  Future<void> save(PairingEnrollment enrollment) async => value = enrollment;
}

final class _Transport implements PairingEnrollmentTransport {
  const _Transport(this.enrollment);

  final PairingEnrollment enrollment;

  @override
  Future<PairingEnrollment> begin() async => enrollment;

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      this.enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      this.enrollment;
}

final class _Telemetry implements PairingEnrollmentTelemetryPort {
  final List<PairingEnrollmentTelemetry> signals =
      <PairingEnrollmentTelemetry>[];

  @override
  void record(PairingEnrollmentTelemetry signal) => signals.add(signal);
}

final class _DeferredTransport implements PairingEnrollmentTransport {
  const _DeferredTransport(this.beginResult);

  final Completer<PairingEnrollment> beginResult;

  @override
  Future<PairingEnrollment> begin() => beginResult.future;

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;
}

final class _RetryTransport implements PairingEnrollmentTransport {
  int beginCalls = 0;

  @override
  Future<PairingEnrollment> begin() async {
    beginCalls++;
    if (beginCalls == 1) throw TimeoutException('unavailable');
    return PairingEnrollment(
      phase: PairingEnrollmentPhase.active,
      updatedAt: DateTime.utc(2026, 8, 30),
    );
  }

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;
}

final class _ProtocolFailureTransport implements PairingEnrollmentTransport {
  const _ProtocolFailureTransport();

  @override
  Future<PairingEnrollment> begin() async =>
      throw const PairingEnrollmentProtocolException();

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      enrollment;
}

final class _UnexpectedLoadStore implements PairingEnrollmentStore {
  const _UnexpectedLoadStore();

  @override
  Future<void> clear() async {}

  @override
  Future<PairingEnrollment?> load() async => throw StateError('unexpected');

  @override
  Future<void> save(PairingEnrollment enrollment) async {}
}

final class _RecordingObserver extends BlocObserver {
  final Completer<void> _error = Completer<void>();
  Object? observed;

  Future<void> get error => _error.future;

  @override
  void onError(BlocBase<Object?> bloc, Object error, StackTrace stackTrace) {
    observed = error;
    if (!_error.isCompleted) _error.complete();
    super.onError(bloc, error, stackTrace);
  }
}
