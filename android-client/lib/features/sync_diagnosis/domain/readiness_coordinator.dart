import 'dart:async';

/// The port owns authenticated, scoped operational probing. It returns only a
/// classified outcome; raw response bytes, headers, endpoint details, and
/// credentials never cross this boundary.
abstract interface class ScopedReadinessProbe {
  Future<ScopedProbeOutcome> probe({required Duration timeout});
}

enum ScopedProbeOutcome { ready, unavailable, unknown }

enum SyncReadinessState { unknown, unavailable, ready }

/// Independent evidence that must exist before a probe may establish readiness.
final class SyncReadinessPrerequisites {
  const SyncReadinessPrerequisites({
    required this.localLockEnrollment,
    required this.durableOutbox,
    required this.syncCoordinator,
    required this.approvedAuthenticatedTransport,
  });

  final bool localLockEnrollment;
  final bool durableOutbox;
  final bool syncCoordinator;
  final bool approvedAuthenticatedTransport;

  bool get complete =>
      localLockEnrollment && durableOutbox && syncCoordinator && approvedAuthenticatedTransport;
}

/// A non-secret, non-payment diagnosis. [ready] means only operational
/// readiness; it never means that any local payment was acknowledged.
final class SyncReadinessSnapshot {
  const SyncReadinessSnapshot(this.state);

  final SyncReadinessState state;
  bool get mayClaimOperationalReadiness => state == SyncReadinessState.ready;
  bool get mayClaimPaymentAcknowledgement => false;
}

/// Bounded, fail-closed coordinator for an already-authorized scoped probe.
final class SyncReadinessCoordinator {
  SyncReadinessCoordinator(this._probe, {this.timeout = const Duration(seconds: 3)})
      : assert(timeout > Duration.zero && timeout <= const Duration(seconds: 3));

  final ScopedReadinessProbe _probe;
  final Duration timeout;

  Future<SyncReadinessSnapshot> refresh(SyncReadinessPrerequisites prerequisites) async {
    if (!prerequisites.complete) {
      return const SyncReadinessSnapshot(SyncReadinessState.unknown);
    }
    try {
      final ScopedProbeOutcome outcome = await _probe.probe(timeout: timeout).timeout(timeout);
      return switch (outcome) {
        ScopedProbeOutcome.ready => const SyncReadinessSnapshot(SyncReadinessState.ready),
        ScopedProbeOutcome.unavailable => const SyncReadinessSnapshot(SyncReadinessState.unavailable),
        ScopedProbeOutcome.unknown => const SyncReadinessSnapshot(SyncReadinessState.unknown),
      };
    } on TimeoutException {
      return const SyncReadinessSnapshot(SyncReadinessState.unavailable);
    } on Object {
      return const SyncReadinessSnapshot(SyncReadinessState.unavailable);
    }
  }
}
