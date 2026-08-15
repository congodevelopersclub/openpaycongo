import 'package:flutter/foundation.dart';

abstract interface class LocalAppAuthenticator { Future<bool> authenticate(); }
abstract interface class LocalPinVerifier { Future<bool> verify(String pin); }

enum AppLockState { locked, verifying, unlocked, backoff, lockedOut }
enum AppLockReason { coldStart, background, backgroundTimeout, cancelled, failed, lockout }

final class AppLockSnapshot {
  const AppLockSnapshot({required this.state, required this.reason, required this.failures, this.nextAttemptAt});
  final AppLockState state;
  final AppLockReason reason;
  final int failures;
  final DateTime? nextAttemptAt;
}

/// Process-local only: verification is injected and no secrets are stored here.
final class AppLockController extends ChangeNotifier {
  AppLockController({
    required this.authenticator,
    required this.pinVerifier,
    this.maxFailures = 5,
    this.backgroundTimeout = const Duration(minutes: 2),
  }) : assert(maxFailures > 0 && maxFailures <= 10), assert(backgroundTimeout > Duration.zero);

  final LocalAppAuthenticator authenticator;
  final LocalPinVerifier pinVerifier;
  final int maxFailures;
  final Duration backgroundTimeout;
  AppLockSnapshot _snapshot = const AppLockSnapshot(state: AppLockState.locked, reason: AppLockReason.coldStart, failures: 0);
  DateTime? _backgroundedAt;
  int _revision = 0;

  AppLockSnapshot get snapshot => _snapshot;
  Future<void> authenticate(DateTime now) => _attempt(now, authenticator.authenticate);
  Future<void> unlockWithPin(String pin, DateTime now) => _attempt(now, () => pinVerifier.verify(pin));

  void background(DateTime now) {
    _revision++;
    _backgroundedAt = now.toUtc();
    _set(AppLockSnapshot(state: AppLockState.locked, reason: AppLockReason.background, failures: _snapshot.failures));
  }

  void resume(DateTime now) {
    final DateTime? backgroundedAt = _backgroundedAt;
    if (backgroundedAt == null) return;
    _backgroundedAt = null;
    if (now.toUtc().difference(backgroundedAt) >= backgroundTimeout) {
      _set(AppLockSnapshot(state: AppLockState.locked, reason: AppLockReason.backgroundTimeout, failures: _snapshot.failures));
    }
  }

  void cancel() {
    _revision++;
    if (_snapshot.state == AppLockState.lockedOut) return;
    _set(AppLockSnapshot(state: AppLockState.locked, reason: AppLockReason.cancelled, failures: _snapshot.failures));
  }

  Future<void> _attempt(DateTime now, Future<bool> Function() verify) async {
    final DateTime normalized = now.toUtc();
    if (!_canAttempt(normalized)) return;
    final int revision = ++_revision;
    _set(AppLockSnapshot(state: AppLockState.verifying, reason: _snapshot.reason, failures: _snapshot.failures));
    bool accepted = false;
    try { accepted = await verify(); } on Object { accepted = false; }
    if (revision != _revision) return;
    if (accepted) {
      _set(const AppLockSnapshot(state: AppLockState.unlocked, reason: AppLockReason.coldStart, failures: 0));
      return;
    }
    final int failures = _snapshot.failures + 1;
    if (failures >= maxFailures) {
      _set(AppLockSnapshot(state: AppLockState.lockedOut, reason: AppLockReason.lockout, failures: failures));
      return;
    }
    _set(AppLockSnapshot(
      state: AppLockState.backoff,
      reason: AppLockReason.failed,
      failures: failures,
      nextAttemptAt: normalized.add(_backoff(failures)),
    ));
  }

  bool _canAttempt(DateTime now) => _snapshot.state != AppLockState.lockedOut &&
      (_snapshot.state != AppLockState.backoff || _snapshot.nextAttemptAt == null || !_snapshot.nextAttemptAt!.isAfter(now));
  Duration _backoff(int failures) {
    const Duration maximum = Duration(minutes: 30);
    final Duration delay = Duration(minutes: 1 << (failures - 1));
    return delay > maximum ? maximum : delay;
  }
  void _set(AppLockSnapshot value) { _snapshot = value; notifyListeners(); }
}
