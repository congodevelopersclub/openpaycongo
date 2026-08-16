import 'operational_transport.dart';

enum OperationalProbeState { checking, healthy, stale, offline, contractFailure, circuitOpen, halfOpen }

final class OperationalProbeSnapshot {
  const OperationalProbeSnapshot._(this.state, {this.observedAt, this.build});

  final OperationalProbeState state;
  final DateTime? observedAt;
  final String? build;
}

/// Lifecycle-only operational evidence. This has neither payment nor
/// acknowledgement capability; a healthy probe never confirms a payment.
final class OperationalProbeLifecycle {
  OperationalProbeLifecycle(this._probe, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final OperationalProbe _probe;
  final DateTime Function() _now;
  int _generation = 0;
  int _transientFailures = 0;
  bool _foreground = false;
  bool _halfOpenInFlight = false;
  DateTime? _openedAt;
  OperationalProbeSnapshot _latest = const OperationalProbeSnapshot._(OperationalProbeState.checking);

  OperationalProbeSnapshot get snapshot {
    final observedAt = _latest.observedAt;
    if (_latest.state == OperationalProbeState.healthy && observedAt != null && _now().difference(observedAt) > const Duration(seconds: 30)) {
      return const OperationalProbeSnapshot._(OperationalProbeState.stale);
    }
    return _latest;
  }

  DateTime? get nextAttemptAt => _openedAt?.add(const Duration(seconds: 30));

  Future<void> onForegroundChanged(bool visible) {
    _foreground = visible;
    if (!visible) {
      _generation++;
      _latest = const OperationalProbeSnapshot._(OperationalProbeState.stale);
      return Future.value();
    }
    _latest = const OperationalProbeSnapshot._(OperationalProbeState.checking);
    return refresh();
  }

  Future<void> refresh() async {
    if (!_foreground) return;
    var isHalfOpen = false;
    final openedAt = _openedAt;
    if (openedAt != null) {
      if (_now().difference(openedAt) < const Duration(seconds: 30)) return;
      if (_halfOpenInFlight) return;
      _halfOpenInFlight = true;
      isHalfOpen = true;
    }
    final generation = ++_generation;
    _latest = isHalfOpen
        ? const OperationalProbeSnapshot._(OperationalProbeState.halfOpen)
        : const OperationalProbeSnapshot._(OperationalProbeState.checking);
    final result = await _probe.probe();
    if (generation != _generation || !_foreground) return;
    _halfOpenInFlight = false;
    if (result.ready) {
      _openedAt = null;
      _transientFailures = 0;
      _latest = OperationalProbeSnapshot._(OperationalProbeState.healthy, observedAt: _now(), build: result.build);
      return;
    }
    if (result.failure == OperationalProbeFailure.schema || result.failure == OperationalProbeFailure.identity) {
      _openedAt = null;
      _transientFailures = 0;
      _latest = const OperationalProbeSnapshot._(OperationalProbeState.contractFailure);
      return;
    }
    _transientFailures++;
    if (_transientFailures >= 3) {
      _openedAt = _now();
      _latest = const OperationalProbeSnapshot._(OperationalProbeState.circuitOpen);
      return;
    }
    _latest = const OperationalProbeSnapshot._(OperationalProbeState.offline);
  }
}
