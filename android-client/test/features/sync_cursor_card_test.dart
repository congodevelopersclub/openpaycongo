import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/presentation/sync_cursor_bloc.dart';
import 'package:opencongopay/features/sync_diagnosis/presentation/sync_cursor_card.dart';

void main() {
  testWidgets('renders loading, empty, offline, and recovered sync states', (
    WidgetTester tester,
  ) async {
    final _ControlledContract contract = _ControlledContract();
    final SyncCursorBloc bloc = SyncCursorBloc(
      store: _Store(),
      contract: contract,
      telemetry: _Telemetry(),
    );
    addTearDown(bloc.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncCursorCard(bloc: bloc)),
      ),
    );
    expect(find.text('No sync cursor'), findsOneWidget);

    bloc.add(const SyncCursorStarted());
    await contract.entered.future;
    await tester.pump();
    expect(find.text('Checking sync'), findsOneWidget);

    contract.complete(
      const SyncCursorReconciliation(
        cursor: null,
        health: SyncCursorHealth.current,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No sync cursor'), findsOneWidget);

    bloc.add(const SyncCursorRetryRequested());
    await tester.pumpAndSettle();
    expect(find.text('Sync offline'), findsOneWidget);
    expect(find.text('Retry sync'), findsOneWidget);

    await tester.tap(find.text('Retry sync'));
    await tester.pumpAndSettle();
    expect(find.text('Sync cursor current'), findsOneWidget);
  });
}

final class _Store implements SyncCursorStore {
  SyncCursor? value;

  @override
  Future<SyncCursor?> load() async => value;

  @override
  Future<void> save(SyncCursor cursor) async {
    value = cursor;
  }
}

final class _ControlledContract implements SyncCursorContract {
  final Completer<void> entered = Completer<void>();
  final Completer<SyncCursorReconciliation> _first =
      Completer<SyncCursorReconciliation>();
  int _calls = 0;

  void complete(SyncCursorReconciliation outcome) {
    _first.complete(outcome);
  }

  @override
  Future<SyncCursorReconciliation> reconcile(SyncCursor? durableCursor) async {
    _calls++;
    if (_calls == 1) {
      entered.complete();
      return _first.future;
    }
    if (_calls == 2) throw const SyncCursorFailure();
    return const SyncCursorReconciliation(
      cursor: SyncCursor('opaque-recovered-cursor'),
      health: SyncCursorHealth.current,
    );
  }
}

final class _Telemetry implements SyncCursorTelemetry {
  @override
  void record(SyncCursorTelemetrySignal signal) {}
}
