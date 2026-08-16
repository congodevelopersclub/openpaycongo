import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/domain/operational_probe_lifecycle.dart';
import 'package:opencongopay/features/sync_diagnosis/domain/operational_transport.dart';

final class ProbeFake implements OperationalProbe {
  ProbeFake(this.results);

  final List<Future<OperationalProbeResult>> results;
  int calls = 0;

  @override
  Future<OperationalProbeResult> probe() => results[calls++];
}

void main() {
  test('visible entry probes automatically and healthy evidence expires', () async {
    var clock = DateTime.utc(2026, 8, 16);
    final lifecycle = OperationalProbeLifecycle(
      ProbeFake([Future.value(OperationalProbeResult.ready('build-1'))]),
      now: () => clock,
    );

    expect(lifecycle.snapshot.state, OperationalProbeState.checking);
    await lifecycle.onForegroundChanged(true);
    expect(lifecycle.snapshot.state, OperationalProbeState.healthy);
    expect(lifecycle.snapshot.observedAt, clock);

    clock = clock.add(const Duration(seconds: 31));
    expect(lifecycle.snapshot.state, OperationalProbeState.stale);
  });

  test('background and resume invalidate evidence, and latest probe supersedes older completion', () async {
    final first = Completer<OperationalProbeResult>();
    final lifecycle = OperationalProbeLifecycle(ProbeFake([
      first.future,
      Future.value(OperationalProbeResult.ready('new')),
    ]));

    final old = lifecycle.onForegroundChanged(true);
    lifecycle.onForegroundChanged(false);
    final fresh = lifecycle.onForegroundChanged(true);
    first.complete(OperationalProbeResult.ready('old'));
    await Future.wait([old, fresh]);

    expect(lifecycle.snapshot.state, OperationalProbeState.healthy);
    expect(lifecycle.snapshot.build, 'new');
  });

  test('three transient failures open circuit and only one half-open probe is admitted', () async {
    var clock = DateTime.utc(2026, 8, 16);
    final halfOpen = Completer<OperationalProbeResult>();
    final probe = ProbeFake([
      ...List.generate(3, (_) => Future.value(OperationalProbeResult.failure(OperationalProbeFailure.http))),
      halfOpen.future,
    ]);
    final lifecycle = OperationalProbeLifecycle(probe, now: () => clock);

    await lifecycle.onForegroundChanged(true);
    for (var i = 0; i < 2; i++) { await lifecycle.refresh(); }
    expect(lifecycle.snapshot.state, OperationalProbeState.circuitOpen);
    expect(lifecycle.nextAttemptAt, clock.add(const Duration(seconds: 30)));
    await lifecycle.refresh();
    expect(probe.calls, 3);

    clock = clock.add(const Duration(seconds: 30));
    final one = lifecycle.refresh();
    final two = lifecycle.refresh();
    expect(lifecycle.snapshot.state, OperationalProbeState.halfOpen);
    halfOpen.complete(OperationalProbeResult.failure(OperationalProbeFailure.http));
    await Future.wait([one, two]);
    expect(probe.calls, 4);
  });
}
