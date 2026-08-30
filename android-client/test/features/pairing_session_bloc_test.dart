import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_session_bloc.dart';

void main() {
  test(
    'persists opaque pending pairing and recovers it after restart',
    () async {
      final _Store store = _Store();
      final _Telemetry telemetry = _Telemetry();
      final PairingSession session = PairingSession(
        sessionId: 'opaque-session-1',
        phase: PairingPhase.pending,
        updatedAt: DateTime.utc(2026),
      );
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: _Gateway(session),
        telemetry: telemetry,
      );
      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PairingSessionLoading>(),
          isA<PairingSessionPending>(),
        ]),
      );
      bloc.add(const PairingSessionStarted());
      await states;
      await bloc.close();
      final PairingSessionBloc restarted = PairingSessionBloc(
        store: store,
        gateway: _Gateway(session),
        telemetry: telemetry,
      );
      final Future<void> recovered = expectLater(
        restarted.stream,
        emits(isA<PairingSessionPending>()),
      );
      restarted.add(const PairingSessionRecovered());
      await recovered;
      expect(telemetry.signals, contains(PairingTelemetrySignal.pending));
      await restarted.close();
    },
  );
  test(
    'timeout stays offline and duplicate start does not create a second request',
    () async {
      final _Store store = _Store();
      final _Telemetry telemetry = _Telemetry();
      final _Gateway gateway = _Gateway(null, timeout: true);
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: telemetry,
      );
      final Future<void> states = expectLater(
        bloc.stream,
        emitsInOrder(<Matcher>[
          isA<PairingSessionLoading>(),
          isA<PairingSessionOffline>(),
        ]),
      );
      bloc
        ..add(const PairingSessionStarted())
        ..add(const PairingSessionStarted());
      await states;
      expect(gateway.calls, 1);
      expect(
        telemetry.signals,
        contains(PairingTelemetrySignal.duplicateIgnored),
      );
      await bloc.close();
    },
  );
  test(
    'cancel during begin leaves no persisted or later pairing state',
    () async {
      final _Store store = _Store();
      final Completer<PairingSession> begin = Completer<PairingSession>();
      final _DeferredGateway gateway = _DeferredGateway(
        begin,
        Completer<PairingSession>(),
      );
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: telemetry,
      );
      bloc.add(const PairingSessionStarted());
      await gateway.beginEntered.future;
      final Future<void> cancelled = telemetry.next(
        PairingTelemetrySignal.cancelled,
      );
      bloc.add(const PairingSessionCancelled());
      await cancelled;
      begin.complete(
        PairingSession(
          sessionId: 'opaque',
          phase: PairingPhase.pending,
          updatedAt: DateTime.utc(2026),
        ),
      );
      await gateway.beginReturned.future;
      expect(bloc.state, isA<PairingSessionIdle>());
      expect(store.value, isNull);
      await bloc.close();
    },
  );
  test(
    'cancel during refresh leaves no persisted or later pairing state',
    () async {
      final _Store store = _Store()
        ..value = PairingSession(
          sessionId: 'opaque',
          phase: PairingPhase.pending,
          updatedAt: DateTime.utc(2026),
        );
      final Completer<PairingSession> refresh = Completer<PairingSession>();
      final _DeferredGateway gateway = _DeferredGateway(
        Completer<PairingSession>(),
        refresh,
      );
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: telemetry,
      );
      bloc.add(const PairingSessionRetryRequested());
      await gateway.refreshEntered.future;
      final Future<void> cancelled = telemetry.next(
        PairingTelemetrySignal.cancelled,
      );
      bloc.add(const PairingSessionCancelled());
      await cancelled;
      refresh.complete(
        PairingSession(
          sessionId: 'opaque',
          phase: PairingPhase.active,
          updatedAt: DateTime.utc(2026),
        ),
      );
      await gateway.refreshReturned.future;
      expect(bloc.state, isA<PairingSessionIdle>());
      expect(store.value, isNull);
      await bloc.close();
    },
  );
  test(
    'cancel during retry load cannot refresh or reapply a stale session',
    () async {
      final PairingSession stale = _session(PairingPhase.pending);
      final _DeferredStore store = _DeferredStore();
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: _Gateway(_session(PairingPhase.active)),
        telemetry: telemetry,
      );

      bloc.add(const PairingSessionRetryRequested());
      await store.loadEntered.future;
      final Future<void> cancelled = telemetry.next(
        PairingTelemetrySignal.cancelled,
      );
      bloc.add(const PairingSessionCancelled());
      await cancelled;
      store.loadResult.complete(stale);
      await store.loadReturned.future;

      expect(bloc.state, isA<PairingSessionIdle>());
      expect(store.value, isNull);
      expect(store.saveCalls, 0);
      await bloc.close();
    },
  );
  test('cancel during recovery load cannot reapply a stale session', () async {
    final PairingSession stale = _session(PairingPhase.pending);
    final _DeferredStore store = _DeferredStore();
    final _Telemetry telemetry = _Telemetry();
    final PairingSessionBloc bloc = PairingSessionBloc(
      store: store,
      gateway: _Gateway(_session(PairingPhase.active)),
      telemetry: telemetry,
    );

    bloc.add(const PairingSessionRecovered());
    await store.loadEntered.future;
    final Future<void> cancelled = telemetry.next(
      PairingTelemetrySignal.cancelled,
    );
    bloc.add(const PairingSessionCancelled());
    await cancelled;
    store.loadResult.complete(stale);
    await store.loadReturned.future;

    expect(bloc.state, isA<PairingSessionIdle>());
    expect(store.value, isNull);
    expect(store.saveCalls, 0);
    await bloc.close();
  });
  test(
    'cancel releases the old operation so an immediate restart owns state',
    () async {
      final _Store store = _Store();
      final Completer<PairingSession> oldBegin = Completer<PairingSession>();
      final _RestartGateway gateway = _RestartGateway(
        oldBegin,
        _session(PairingPhase.pending),
      );
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: telemetry,
      );

      bloc.add(const PairingSessionStarted());
      await gateway.oldBeginEntered.future;
      final Future<void> cancelled = telemetry.next(
        PairingTelemetrySignal.cancelled,
      );
      bloc.add(const PairingSessionCancelled());
      await cancelled;
      final Future<PairingSessionState> pending = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionPending,
      );
      bloc.add(const PairingSessionStarted());
      await pending;

      oldBegin.complete(_session(PairingPhase.active));
      await gateway.oldBeginReturned.future;

      expect(gateway.calls, 2);
      expect(bloc.state, isA<PairingSessionPending>());
      expect(
        (bloc.state as PairingSessionPending).session,
        same(gateway.restart),
      );
      expect(store.value, same(gateway.restart));
      await bloc.close();
    },
  );
  test(
    'restart confirmation waits for a deferred prior save to settle',
    () async {
      final PairingSession newSession = _session(PairingPhase.pending);
      final _DeferredFirstSaveStore store = _DeferredFirstSaveStore(newSession);
      final Completer<PairingSession> oldBegin = Completer<PairingSession>();
      final _RestartGateway gateway = _RestartGateway(oldBegin, newSession);
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: telemetry,
      );

      bloc.add(const PairingSessionStarted());
      await gateway.oldBeginEntered.future;
      oldBegin.complete(_session(PairingPhase.active));
      await store.oldSaveEntered.future;
      final Future<void> cancelled = telemetry.next(
        PairingTelemetrySignal.cancelled,
      );
      bloc.add(const PairingSessionCancelled());
      await cancelled;
      final Future<PairingSessionState> pending = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionPending,
      );
      bloc.add(const PairingSessionStarted());
      expect(bloc.state, isA<PairingSessionLoading>());

      store.releaseOldSave.complete();
      await pending;
      await store.newSavePersisted.future;
      await gateway.oldBeginReturned.future;
      await store.oldSaveOutcome.future;

      expect(bloc.state, isA<PairingSessionPending>());
      expect(store.value, same(newSession));
      await bloc.close();
    },
  );
  test('recovery is ignored while a live operation owns the session', () async {
    final _Store store = _Store()..value = _session(PairingPhase.pending);
    final Completer<PairingSession> begin = Completer<PairingSession>();
    final _DeferredGateway gateway = _DeferredGateway(
      begin,
      Completer<PairingSession>(),
    );
    final _Telemetry telemetry = _Telemetry();
    final PairingSessionBloc bloc = PairingSessionBloc(
      store: store,
      gateway: gateway,
      telemetry: telemetry,
    );

    bloc.add(const PairingSessionStarted());
    await gateway.beginEntered.future;
    final Future<void> ignored = telemetry.next(
      PairingTelemetrySignal.duplicateIgnored,
    );
    bloc.add(const PairingSessionRecovered());
    await ignored;
    expect(store.saveCalls, 0);

    final Future<PairingSessionState> active = bloc.stream.firstWhere(
      (PairingSessionState state) => state is PairingSessionActive,
    );
    begin.complete(_session(PairingPhase.active));
    await active;
    expect(store.value!.phase, PairingPhase.active);
    await bloc.close();
  });
  test(
    'restart waits for cancellation cleanup before confirming durable pairing',
    () async {
      final PairingSession oldSession = _session(PairingPhase.pending);
      final PairingSession newSession = _session(PairingPhase.pending);
      final _DeferredClearStore store = _DeferredClearStore();
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: _SequenceGateway(<PairingSession>[oldSession, newSession]),
        telemetry: telemetry,
      );

      final Future<PairingSessionState> oldPending = bloc.stream.firstWhere(
        (PairingSessionState state) =>
            state is PairingSessionPending && state.session == oldSession,
      );
      bloc.add(const PairingSessionStarted());
      await oldPending;

      bloc.add(const PairingSessionCancelled());
      await store.clearEntered.future;
      expect(
        telemetry.signals.where(
          (PairingTelemetrySignal signal) =>
              signal == PairingTelemetrySignal.cancelled,
        ),
        hasLength(1),
      );
      final Future<PairingSessionState> newPending = bloc.stream.firstWhere(
        (PairingSessionState state) =>
            state is PairingSessionPending && state.session == newSession,
      );
      final Future<void> restartStarted = telemetry.next(
        PairingTelemetrySignal.started,
      );
      bloc.add(const PairingSessionStarted());
      await restartStarted;
      expect(bloc.state, isA<PairingSessionLoading>());
      expect(store.value, same(oldSession));

      store.releaseClear.complete();
      await newPending;
      await store.newSessionRestored.future;

      expect(bloc.state, isA<PairingSessionPending>());
      expect((bloc.state as PairingSessionPending).session, same(newSession));
      expect(store.value, same(newSession));
      expect(
        telemetry.signals.where(
          (PairingTelemetrySignal signal) =>
              signal == PairingTelemetrySignal.cancelled,
        ),
        hasLength(1),
      );
      await bloc.close();
    },
  );
  test(
    'a second cancel owns a superseding start while earlier cleanup is pending',
    () async {
      final PairingSession first = _session(PairingPhase.pending);
      final PairingSession second = PairingSession(
        sessionId: 'second',
        phase: PairingPhase.pending,
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      final _TwoStageDeferredClearStore store = _TwoStageDeferredClearStore();
      final _SupersededCancelGateway gateway = _SupersededCancelGateway(first);
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: telemetry,
      );
      final Future<PairingSessionState> firstPending = bloc.stream.firstWhere(
        (PairingSessionState state) =>
            state is PairingSessionPending && state.session == first,
      );
      bloc.add(const PairingSessionStarted());
      await firstPending;

      bloc.add(const PairingSessionCancelled());
      await store.firstClearEntered.future;
      bloc.add(const PairingSessionStarted());
      await gateway.secondBeginEntered.future;
      final Future<void> secondCancelled = telemetry.next(
        PairingTelemetrySignal.cancelled,
      );
      bloc.add(const PairingSessionCancelled());
      await secondCancelled;
      expect(
        telemetry.signals.where(
          (PairingTelemetrySignal signal) =>
              signal == PairingTelemetrySignal.cancelled,
        ),
        hasLength(2),
      );

      gateway.completeSecond(second);
      await gateway.secondBeginReturned.future;
      final Future<PairingSessionState> idle = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionIdle,
      );
      store.releaseFirstClear.complete();
      await store.secondClearEntered.future;
      store.releaseSecondClear.complete();
      await idle;

      expect(bloc.state, isA<PairingSessionIdle>());
      expect(store.value, isNull);
      expect(store.saveCalls, 1);
      expect(
        telemetry.signals.where(
          (PairingTelemetrySignal signal) =>
              signal == PairingTelemetrySignal.pending ||
              signal == PairingTelemetrySignal.active,
        ),
        hasLength(1),
      );
      await bloc.close();
    },
  );
  test(
    'retry and recovery during cancel cleanup cannot revive a session',
    () async {
      final PairingSession oldSession = _session(PairingPhase.pending);
      final _DeferredClearStore store = _DeferredClearStore();
      final _Gateway gateway = _Gateway(oldSession);
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: _Telemetry(),
      );
      final Future<PairingSessionState> pending = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionPending,
      );
      bloc.add(const PairingSessionStarted());
      await pending;
      expect(store.value, same(oldSession));

      bloc.add(const PairingSessionCancelled());
      await store.clearEntered.future;
      bloc
        ..add(const PairingSessionRetryRequested())
        ..add(const PairingSessionRecovered());
      expect(gateway.calls, 1);

      final Future<PairingSessionState> idle = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionIdle,
      );
      store.releaseClear.complete();
      await idle;
      expect(bloc.state, isA<PairingSessionIdle>());
      expect(store.value, isNull);
      expect(gateway.calls, 1);
      await bloc.close();
    },
  );
  test(
    'cancel waits for a pre-cancel deferred save before reporting idle',
    () async {
      final PairingSession session = _session(PairingPhase.pending);
      final _DeferredFirstSaveStore store = _DeferredFirstSaveStore(session);
      final Completer<PairingSession> begin = Completer<PairingSession>();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: _DeferredGateway(begin, Completer<PairingSession>()),
        telemetry: _Telemetry(),
      );
      bloc.add(const PairingSessionStarted());
      begin.complete(session);
      await store.oldSaveEntered.future;
      final Future<PairingSessionState> idle = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionIdle,
      );
      bloc.add(const PairingSessionCancelled());
      expect(bloc.state, isA<PairingSessionLoading>());
      store.releaseOldSave.complete();
      await idle;
      expect(store.value, isNull);
      await bloc.close();
    },
  );
  test('duplicate cancel owns one cleanup and emits telemetry once', () async {
    final _DeferredClearStore store = _DeferredClearStore();
    final _Telemetry telemetry = _Telemetry();
    final PairingSessionBloc bloc = PairingSessionBloc(
      store: store,
      gateway: _Gateway(_session(PairingPhase.pending)),
      telemetry: telemetry,
    );
    bloc
      ..add(const PairingSessionCancelled())
      ..add(const PairingSessionCancelled());
    await store.clearEntered.future;
    expect(
      telemetry.signals.where(
        (PairingTelemetrySignal signal) =>
            signal == PairingTelemetrySignal.cancelled,
      ),
      hasLength(1),
    );
    store.releaseClear.complete();
    await store.clearReturned.future;
    expect(store.value, isNull);
    await bloc.close();
  });
  test(
    'retry and recovery share one resumed clear after a transient failure',
    () async {
      final PairingSession stale = _session(PairingPhase.pending);
      final _FailOnceClearStore store = _FailOnceClearStore()..value = stale;
      final _Gateway gateway = _Gateway(stale);
      final List<PairingSessionState> transitions = <PairingSessionState>[];
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: _Telemetry(),
      );
      final StreamSubscription<PairingSessionState> subscription = bloc.stream
          .listen(transitions.add);
      final Future<PairingSessionState> offline = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionOffline,
      );
      bloc.add(const PairingSessionCancelled());
      await store.firstClearAttempt.future;
      await offline;
      expect(bloc.state, isA<PairingSessionOffline>());
      bloc
        ..add(const PairingSessionRetryRequested())
        ..add(const PairingSessionRecovered());
      final Future<PairingSessionState> idle = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionIdle,
      );
      await store.resumedClearEntered.future;
      expect(store.clearCalls, 2);
      expect(store.loadCalls, 0);
      expect(store.saveCalls, 0);
      expect(gateway.calls, 0);
      expect(bloc.state, isA<PairingSessionOffline>());
      store.releaseResumedClear.complete();
      await idle;
      expect(bloc.state, isA<PairingSessionIdle>());
      expect(store.value, isNull);
      expect(store.clearCalls, 2);
      expect(
        transitions.map((PairingSessionState state) => state.runtimeType),
        <Type>[PairingSessionOffline, PairingSessionIdle],
      );
      expect(gateway.calls, 0);
      await subscription.cancel();
      await bloc.close();
    },
  );
  test('fresh start supersedes a failed cancellation cleanup', () async {
    final PairingSession stale = _session(PairingPhase.pending);
    final PairingSession replacement = PairingSession(
      sessionId: 'replacement',
      phase: PairingPhase.pending,
      updatedAt: DateTime.utc(2026, 1, 2),
    );
    final _FailOnceClearStore store = _FailOnceClearStore()..value = stale;
    final PairingSessionBloc bloc = PairingSessionBloc(
      store: store,
      gateway: _Gateway(replacement),
      telemetry: _Telemetry(),
    );
    final List<PairingSessionState> transitions = <PairingSessionState>[];
    final StreamSubscription<PairingSessionState> subscription = bloc.stream
        .listen(transitions.add);
    final Future<PairingSessionState> offline = bloc.stream.firstWhere(
      (PairingSessionState state) => state is PairingSessionOffline,
    );
    bloc.add(const PairingSessionCancelled());
    await store.firstClearAttempt.future;
    await offline;
    final Future<PairingSessionState> pending = bloc.stream.firstWhere(
      (PairingSessionState state) => state is PairingSessionPending,
    );
    bloc.add(const PairingSessionStarted());
    await pending;
    expect(bloc.state, isA<PairingSessionPending>());
    expect(store.value, same(replacement));
    expect(store.clearCalls, 1);
    expect(transitions.whereType<PairingSessionIdle>(), isEmpty);
    await subscription.cancel();
    await bloc.close();
  });
  test(
    'superseding start timeout still clears the cancelled durable session',
    () async {
      final PairingSession stale = _session(PairingPhase.pending);
      final _DeferredFirstSaveStore store = _DeferredFirstSaveStore(stale);
      final _FirstThenTimeoutGateway gateway = _FirstThenTimeoutGateway(stale);
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: gateway,
        telemetry: _Telemetry(),
      );
      bloc.add(const PairingSessionStarted());
      await store.oldSaveEntered.future;
      bloc.add(const PairingSessionCancelled());
      bloc.add(const PairingSessionStarted());
      final Future<PairingSessionState> offline = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionOffline,
      );
      store.releaseOldSave.complete();
      await offline;
      expect(store.value, isNull);
      final Future<PairingSessionState> idle = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionIdle,
      );
      bloc.add(const PairingSessionRecovered());
      await idle;
      expect(bloc.state, isA<PairingSessionIdle>());
      await bloc.close();
    },
  );
  for (final PairingSessionEvent event in <PairingSessionEvent>[
    const PairingSessionStarted(),
    const PairingSessionRetryRequested(),
    const PairingSessionRecovered(),
  ]) {
    test('typed persistence failure emits offline for $event', () async {
      final PairingSession session = _session(PairingPhase.pending);
      final _FailingSaveStore store = _FailingSaveStore()..value = session;
      final _Telemetry telemetry = _Telemetry();
      final PairingSessionBloc bloc = PairingSessionBloc(
        store: store,
        gateway: _Gateway(session),
        telemetry: telemetry,
      );
      final Future<PairingSessionState> offline = bloc.stream.firstWhere(
        (PairingSessionState state) => state is PairingSessionOffline,
      );
      bloc.add(event);
      await offline;
      expect(bloc.state, isA<PairingSessionOffline>());
      expect(telemetry.signals, contains(PairingTelemetrySignal.offline));
      await bloc.close();
    });
  }
}

PairingSession _session(PairingPhase phase) => PairingSession(
  sessionId: 'opaque',
  phase: phase,
  updatedAt: DateTime.utc(2026),
);

class _Store implements PairingSessionStore {
  PairingSession? value;
  int saveCalls = 0;
  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<PairingSession?> load() async => value;
  @override
  Future<void> save(PairingSession session) async {
    saveCalls++;
    value = session;
  }
}

final class _Gateway implements PairingSessionGateway {
  _Gateway(this.value, {this.timeout = false});
  final PairingSession? value;
  final bool timeout;
  int calls = 0;
  @override
  Future<PairingSession> begin() async {
    calls++;
    if (timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      throw TimeoutException('offline');
    }
    return value!;
  }

  @override
  Future<PairingSession> refresh(String sessionId) => begin();
}

final class _Telemetry implements PairingTelemetry {
  final List<PairingTelemetrySignal> signals = [];

  final Map<PairingTelemetrySignal, List<Completer<void>>> _waiters =
      <PairingTelemetrySignal, List<Completer<void>>>{};

  Future<void> next(PairingTelemetrySignal signal) {
    final Completer<void> waiter = Completer<void>();
    _waiters.putIfAbsent(signal, () => <Completer<void>>[]).add(waiter);
    return waiter.future;
  }

  @override
  void record(PairingTelemetrySignal signal) {
    signals.add(signal);
    final List<Completer<void>>? waiters = _waiters.remove(signal);
    for (final Completer<void> waiter in waiters ?? <Completer<void>>[]) {
      waiter.complete();
    }
  }
}

final class _DeferredGateway implements PairingSessionGateway {
  _DeferredGateway(this.beginResult, this.refreshResult);
  final Completer<PairingSession> beginResult;
  final Completer<PairingSession> refreshResult;
  final Completer<void> beginEntered = Completer<void>();
  final Completer<void> beginReturned = Completer<void>();
  final Completer<void> refreshEntered = Completer<void>();
  final Completer<void> refreshReturned = Completer<void>();
  @override
  Future<PairingSession> begin() async {
    beginEntered.complete();
    final PairingSession session = await beginResult.future;
    beginReturned.complete();
    return session;
  }

  @override
  Future<PairingSession> refresh(String sessionId) async {
    refreshEntered.complete();
    final PairingSession session = await refreshResult.future;
    refreshReturned.complete();
    return session;
  }
}

final class _DeferredStore extends _Store {
  final Completer<PairingSession?> loadResult = Completer<PairingSession?>();
  final Completer<void> loadEntered = Completer<void>();
  final Completer<void> loadReturned = Completer<void>();

  @override
  Future<PairingSession?> load() async {
    loadEntered.complete();
    final PairingSession? session = await loadResult.future;
    loadReturned.complete();
    return session;
  }
}

final class _RestartGateway implements PairingSessionGateway {
  _RestartGateway(this.oldBegin, this.restart);

  final Completer<PairingSession> oldBegin;
  final PairingSession restart;
  final Completer<void> oldBeginEntered = Completer<void>();
  final Completer<void> oldBeginReturned = Completer<void>();
  int calls = 0;

  @override
  Future<PairingSession> begin() async {
    calls++;
    if (calls == 1) {
      oldBeginEntered.complete();
      final PairingSession session = await oldBegin.future;
      oldBeginReturned.complete();
      return session;
    }
    return restart;
  }

  @override
  Future<PairingSession> refresh(String sessionId) => begin();
}

final class _DeferredFirstSaveStore extends _Store {
  _DeferredFirstSaveStore(this.newSession);

  final PairingSession newSession;
  final Completer<void> oldSaveEntered = Completer<void>();
  final Completer<void> releaseOldSave = Completer<void>();
  final Completer<void> newSavePersisted = Completer<void>();
  final Completer<void> oldSaveOutcome = Completer<void>();
  bool _oldSaveReturned = false;

  @override
  Future<void> save(PairingSession session) async {
    saveCalls++;
    if (saveCalls == 1) {
      oldSaveEntered.complete();
      await releaseOldSave.future;
      value = session;
      _oldSaveReturned = true;
      return;
    }
    value = session;
    if (identical(session, newSession) && !newSavePersisted.isCompleted) {
      newSavePersisted.complete();
    }
    if (_oldSaveReturned && !oldSaveOutcome.isCompleted) {
      oldSaveOutcome.complete();
    }
  }

  @override
  Future<void> clear() async {
    await super.clear();
    if (_oldSaveReturned && !oldSaveOutcome.isCompleted) {
      oldSaveOutcome.complete();
    }
  }
}

final class _DeferredClearStore extends _Store {
  final Completer<void> clearEntered = Completer<void>();
  final Completer<void> releaseClear = Completer<void>();
  final Completer<void> clearReturned = Completer<void>();
  final Completer<void> newSessionRestored = Completer<void>();
  bool _clearReturned = false;

  @override
  Future<void> clear() async {
    clearEntered.complete();
    await releaseClear.future;
    value = null;
    _clearReturned = true;
    clearReturned.complete();
  }

  @override
  Future<void> save(PairingSession session) async {
    saveCalls++;
    value = session;
    if (_clearReturned && !newSessionRestored.isCompleted) {
      newSessionRestored.complete();
    }
  }
}

final class _TwoStageDeferredClearStore extends _Store {
  final Completer<void> firstClearEntered = Completer<void>();
  final Completer<void> releaseFirstClear = Completer<void>();
  final Completer<void> secondClearEntered = Completer<void>();
  final Completer<void> releaseSecondClear = Completer<void>();
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearCalls == 1) {
      firstClearEntered.complete();
      await releaseFirstClear.future;
    } else {
      secondClearEntered.complete();
      await releaseSecondClear.future;
    }
    value = null;
  }
}

final class _FailOnceClearStore extends _Store {
  final Completer<void> firstClearAttempt = Completer<void>();
  final Completer<void> resumedClearEntered = Completer<void>();
  final Completer<void> releaseResumedClear = Completer<void>();
  final Completer<void> successfulClear = Completer<void>();
  int clearCalls = 0;
  int loadCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearCalls == 1) {
      firstClearAttempt.complete();
      throw const PairingSessionPersistenceException();
    }
    resumedClearEntered.complete();
    await releaseResumedClear.future;
    value = null;
    successfulClear.complete();
  }

  @override
  Future<PairingSession?> load() async {
    loadCalls++;
    return super.load();
  }
}

final class _FailingSaveStore extends _Store {
  @override
  Future<void> save(PairingSession session) async {
    throw const PairingSessionPersistenceException();
  }
}

final class _FirstThenTimeoutGateway implements PairingSessionGateway {
  _FirstThenTimeoutGateway(this.first);
  final PairingSession first;
  int calls = 0;

  @override
  Future<PairingSession> begin() async {
    calls++;
    if (calls == 1) return first;
    throw TimeoutException('offline');
  }

  @override
  Future<PairingSession> refresh(String sessionId) => begin();
}

final class _SequenceGateway implements PairingSessionGateway {
  _SequenceGateway(this.sessions);

  final List<PairingSession> sessions;
  int _next = 0;

  @override
  Future<PairingSession> begin() async => sessions[_next++];

  @override
  Future<PairingSession> refresh(String sessionId) => begin();
}

final class _SupersededCancelGateway implements PairingSessionGateway {
  _SupersededCancelGateway(this.first);

  final PairingSession first;
  final Completer<PairingSession> _second = Completer<PairingSession>();
  final Completer<void> secondBeginEntered = Completer<void>();
  final Completer<void> secondBeginReturned = Completer<void>();
  int calls = 0;

  @override
  Future<PairingSession> begin() async {
    calls++;
    if (calls == 1) return first;
    secondBeginEntered.complete();
    final PairingSession session = await _second.future;
    secondBeginReturned.complete();
    return session;
  }

  void completeSecond(PairingSession session) => _second.complete(session);

  @override
  Future<PairingSession> refresh(String sessionId) => begin();
}
