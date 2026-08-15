import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/domain/readiness_coordinator.dart';

final class ProbeFake implements ScopedReadinessProbe {
  ProbeFake(this.result);

  final Future<ScopedProbeOutcome> result;
  int calls = 0;
  Duration? requestedTimeout;

  @override
  Future<ScopedProbeOutcome> probe({required Duration timeout}) {
    calls++;
    requestedTimeout = timeout;
    return result;
  }
}

const SyncReadinessPrerequisites complete = SyncReadinessPrerequisites(
  localLockEnrollment: true,
  durableOutbox: true,
  syncCoordinator: true,
  approvedAuthenticatedTransport: true,
);

void main() {
  test('missing independent evidence is unknown and makes zero probe calls', () async {
    final ProbeFake probe = ProbeFake(Future<ScopedProbeOutcome>.value(ScopedProbeOutcome.ready));
    final SyncReadinessSnapshot snapshot = await SyncReadinessCoordinator(probe).refresh(
      const SyncReadinessPrerequisites(
        localLockEnrollment: true,
        durableOutbox: true,
        syncCoordinator: true,
        approvedAuthenticatedTransport: false,
      ),
    );

    expect(snapshot.state, SyncReadinessState.unknown);
    expect(snapshot.mayClaimOperationalReadiness, isFalse);
    expect(snapshot.mayClaimPaymentAcknowledgement, isFalse);
    expect(probe.calls, 0);
  });

  test('only a successful scoped probe with all prerequisites reports ready', () async {
    final ProbeFake probe = ProbeFake(Future<ScopedProbeOutcome>.value(ScopedProbeOutcome.ready));
    final SyncReadinessSnapshot snapshot = await SyncReadinessCoordinator(probe).refresh(complete);

    expect(snapshot.state, SyncReadinessState.ready);
    expect(snapshot.mayClaimOperationalReadiness, isTrue);
    expect(snapshot.mayClaimPaymentAcknowledgement, isFalse);
    expect(probe.calls, 1);
    expect(probe.requestedTimeout, const Duration(seconds: 3));
  });

  test('unavailable, unknown, and timed out probes remain fail closed', () async {
    final ProbeFake unavailable = ProbeFake(Future<ScopedProbeOutcome>.value(ScopedProbeOutcome.unavailable));
    expect((await SyncReadinessCoordinator(unavailable).refresh(complete)).state, SyncReadinessState.unavailable);

    final ProbeFake unknown = ProbeFake(Future<ScopedProbeOutcome>.value(ScopedProbeOutcome.unknown));
    expect((await SyncReadinessCoordinator(unknown).refresh(complete)).state, SyncReadinessState.unknown);

    final Completer<ScopedProbeOutcome> pending = Completer<ScopedProbeOutcome>();
    final ProbeFake timeout = ProbeFake(pending.future);
    expect(
      (await SyncReadinessCoordinator(timeout, timeout: const Duration(milliseconds: 1)).refresh(complete)).state,
      SyncReadinessState.unavailable,
    );
  });
}
