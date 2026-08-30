import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/presentation/sync_cursor_bloc.dart';

void main() {
  test(
    'persists a reconciled opaque cursor and restores it after restart',
    () async {
      final _Store store = _Store();
      final SyncCursor cursor = SyncCursor('cursor-1');
      final SyncCursorBloc bloc = SyncCursorBloc(
        store: store,
        contract: _Contract(cursor),
        telemetry: _Telemetry(),
      );
      final Future<SyncCursorState> synced = bloc.stream.firstWhere(
        (state) => state is SyncCursorSynced,
      );
      bloc.add(const SyncCursorStarted());
      await synced;
      expect(store.value?.value, 'cursor-1');
      await bloc.close();
      final SyncCursorBloc restarted = SyncCursorBloc(
        store: store,
        contract: _Contract(cursor),
        telemetry: _Telemetry(),
      );
      final Future<SyncCursorState> restored = restarted.stream.firstWhere(
        (state) => state is SyncCursorSynced,
      );
      restarted.add(const SyncCursorRecovered());
      await restored;
      await restarted.close();
    },
  );

  test('duplicate delivery is not persisted twice', () async {
    final SyncCursor cursor = SyncCursor('cursor-1');
    final _Store store = _Store()..value = cursor;
    final _Telemetry telemetry = _Telemetry();
    final SyncCursorBloc bloc = SyncCursorBloc(
      store: store,
      contract: _Contract(cursor),
      telemetry: telemetry,
    );
    bloc.add(SyncCursorDeliveryReceived(cursor));
    await bloc.stream.firstWhere((state) => state is SyncCursorSynced);
    expect(store.saves, 0);
    expect(telemetry.signals, <SyncCursorTelemetrySignal>[
      SyncCursorTelemetrySignal.duplicateIgnored,
    ]);
    await bloc.close();
  });

  test('typed contract failure is offline and retry recovers', () async {
    final _FlakyContract contract = _FlakyContract(SyncCursor('cursor-2'));
    final _Telemetry telemetry = _Telemetry();
    final SyncCursorBloc bloc = SyncCursorBloc(
      store: _Store(),
      contract: contract,
      telemetry: telemetry,
    );
    bloc.add(const SyncCursorStarted());
    await bloc.stream.firstWhere((state) => state is SyncCursorOffline);
    bloc.add(const SyncCursorRetryRequested());
    await bloc.stream.firstWhere((state) => state is SyncCursorSynced);
    expect(telemetry.signals, contains(SyncCursorTelemetrySignal.offline));
    await bloc.close();
  });

  test('stale cursor reconciliation remains explicit and durable', () async {
    final _Store store = _Store()..value = SyncCursor('cursor-old');
    final _Telemetry telemetry = _Telemetry();
    final SyncCursorBloc bloc = SyncCursorBloc(
      store: store,
      contract: _Contract(
        SyncCursor('cursor-new'),
        health: SyncCursorHealth.stale,
      ),
      telemetry: telemetry,
    );
    final Future<SyncCursorState> stale = bloc.stream.firstWhere(
      (SyncCursorState state) => state is SyncCursorStale,
    );
    bloc.add(const SyncCursorStarted());
    await stale;
    expect(store.value?.value, 'cursor-new');
    expect(telemetry.signals, contains(SyncCursorTelemetrySignal.staleCursor));
    await bloc.close();
  });

  test('degraded reconciliation is distinct from offline', () async {
    final SyncCursorBloc bloc = SyncCursorBloc(
      store: _Store(),
      contract: _Contract(
        SyncCursor('cursor-3'),
        health: SyncCursorHealth.degraded,
      ),
      telemetry: _Telemetry(),
    );
    final Future<SyncCursorState> degraded = bloc.stream.firstWhere(
      (SyncCursorState state) => state is SyncCursorDegraded,
    );
    bloc.add(const SyncCursorStarted());
    await degraded;
    expect(bloc.state, isA<SyncCursorDegraded>());
    await bloc.close();
  });

  test('unexpected contract errors are not mapped to offline', () async {
    final _ObservingBlocObserver observer = _ObservingBlocObserver();
    final BlocObserver previous = Bloc.observer;
    Bloc.observer = observer;
    addTearDown(() => Bloc.observer = previous);
    final Completer<Object> uncaught = Completer<Object>();
    late final SyncCursorBloc bloc;
    runZonedGuarded(() {
      bloc = SyncCursorBloc(
        store: _UnexpectedStore(),
        contract: _Contract(null),
        telemetry: _Telemetry(),
      );
      bloc.add(const SyncCursorStarted());
    }, (Object error, StackTrace _) => uncaught.complete(error));
    await observer.error;
    expect(await uncaught.future, isA<StateError>());
    expect(bloc.state, isA<SyncCursorLoading>());
    await bloc.close();
  });
}

final class _Store implements SyncCursorStore {
  SyncCursor? value;
  int saves = 0;

  @override
  Future<SyncCursor?> load() async => value;

  @override
  Future<void> save(SyncCursor cursor) async {
    saves++;
    value = cursor;
  }
}

final class _Contract implements SyncCursorContract {
  _Contract(this.value, {this.health = SyncCursorHealth.current});

  final SyncCursor? value;
  final SyncCursorHealth health;

  @override
  Future<SyncCursorReconciliation> reconcile(SyncCursor? cursor) async {
    return SyncCursorReconciliation(cursor: value, health: health);
  }
}

final class _FlakyContract implements SyncCursorContract {
  _FlakyContract(this.value);

  final SyncCursor value;
  bool first = true;

  @override
  Future<SyncCursorReconciliation> reconcile(SyncCursor? cursor) async {
    if (first) {
      first = false;
      throw const SyncCursorFailure();
    }
    return SyncCursorReconciliation(
      cursor: value,
      health: SyncCursorHealth.current,
    );
  }
}

final class _Telemetry implements SyncCursorTelemetry {
  final List<SyncCursorTelemetrySignal> signals = <SyncCursorTelemetrySignal>[];

  @override
  void record(SyncCursorTelemetrySignal signal) => signals.add(signal);
}

final class _UnexpectedStore implements SyncCursorStore {
  @override
  Future<SyncCursor?> load() async =>
      throw StateError('unexpected store error');

  @override
  Future<void> save(SyncCursor cursor) async {}
}

final class _ObservingBlocObserver extends BlocObserver {
  final Completer<void> _error = Completer<void>();

  Future<void> get error => _error.future;

  @override
  void onError(BlocBase<Object?> bloc, Object error, StackTrace stackTrace) {
    _error.complete();
    super.onError(bloc, error, stackTrace);
  }
}
