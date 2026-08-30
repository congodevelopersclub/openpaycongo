import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/app_lock/presentation/app_lock_bloc.dart';

void main() {
  test('a stale PIN success cannot unlock after lifecycle relock', () async {
    final _LockPort port = _LockPort();
    final AppLockBloc bloc = AppLockBloc(port: port);
    final Future<void> states = expectLater(
      bloc.stream,
      emitsInOrder(<Matcher>[isA<AppLockPinVerifying>(), isA<AppLockLocked>()]),
    );

    bloc.add(const AppLockPinSubmitted('123456'));
    await Future<void>.delayed(Duration.zero);
    bloc.add(const AppLockLifecycleChanged(AppLockLifecycle.background));
    port.pin.complete(const AppLockPinResult.unlocked());
    await states;

    expect(bloc.state, isA<AppLockLocked>());
    expect(port.lockCalls, 1);
    await bloc.close();
  });

  test(
    'a cooldown becomes eligible and can unlock with a fresh PIN result',
    () async {
      DateTime now = DateTime.utc(2026, 8, 30, 10);
      final _TimerFactory timers = _TimerFactory();
      final AppLockBloc bloc = AppLockBloc(
        port: _CooldownPort(),
        now: () => now,
        timer: timers.call,
      );

      bloc.add(const AppLockPinSubmitted('123456'));
      await Future<void>.delayed(Duration.zero);
      expect(
        (bloc.state as AppLockLocked).cooldownUntil,
        now.add(const Duration(minutes: 1)),
      );

      now = now.add(const Duration(minutes: 1));
      timers.fire(0);
      await Future<void>.delayed(Duration.zero);
      expect((bloc.state as AppLockLocked).cooldownUntil, isNull);

      bloc.add(const AppLockPinSubmitted('123456'));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state, isA<AppLockUnlocked>());
      await bloc.close();
    },
  );

  test(
    'a cancelled cooldown timer cannot change a later lifecycle lock',
    () async {
      final DateTime now = DateTime.utc(2026, 8, 30, 10);
      final _TimerFactory timers = _TimerFactory();
      final _CooldownPort port = _CooldownPort();
      final AppLockBloc bloc = AppLockBloc(
        port: port,
        now: () => now,
        timer: timers.call,
      );

      bloc.add(const AppLockPinSubmitted('123456'));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const AppLockLifecycleChanged(AppLockLifecycle.background));
      await Future<void>.delayed(Duration.zero);
      timers.fire(0);
      await Future<void>.delayed(Duration.zero);

      expect(timers.cancelled, isTrue);
      expect(bloc.state, isA<AppLockLocked>());
      expect((bloc.state as AppLockLocked).cooldownUntil, isNull);
      expect(port.lockCalls, 1);
      await bloc.close();
    },
  );

  test('an early cooldown callback cannot make the PIN eligible', () async {
    DateTime now = DateTime.utc(2026, 8, 30, 10);
    final _TimerFactory timers = _TimerFactory();
    final AppLockBloc bloc = AppLockBloc(
      port: _CooldownPort(),
      now: () => now,
      timer: timers.call,
    );

    bloc.add(const AppLockPinSubmitted('123456'));
    await Future<void>.delayed(Duration.zero);
    timers.fire(0);
    await Future<void>.delayed(Duration.zero);

    expect(
      (bloc.state as AppLockLocked).cooldownUntil,
      DateTime.utc(2026, 8, 30, 10, 1),
    );
    expect(timers.callbacks, hasLength(2));

    now = now.add(const Duration(minutes: 1));
    timers.fire(1);
    await Future<void>.delayed(Duration.zero);
    expect((bloc.state as AppLockLocked).cooldownUntil, isNull);
    await bloc.close();
  });

  test('an old timer cannot clear a newer cooldown', () async {
    final DateTime now = DateTime.utc(2026, 8, 30, 10);
    final _TimerFactory timers = _TimerFactory();
    final AppLockBloc bloc = AppLockBloc(
      port: _CooldownPort(
        results: <AppLockPinResult>[
          AppLockPinResult.cooldown(DateTime.utc(2026, 8, 30, 10, 1)),
          AppLockPinResult.cooldown(DateTime.utc(2026, 8, 30, 10, 2)),
        ],
      ),
      now: () => now,
      timer: timers.call,
    );

    bloc
      ..add(const AppLockPinSubmitted('123456'))
      ..add(const AppLockPinSubmitted('123456'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(timers.callbacks, hasLength(2));

    timers.fire(0);
    await Future<void>.delayed(Duration.zero);
    expect(
      (bloc.state as AppLockLocked).cooldownUntil,
      DateTime.utc(2026, 8, 30, 10, 2),
    );
    await bloc.close();
  });
}

final class _LockPort implements AppLockPort {
  final Completer<AppLockPinResult> pin = Completer<AppLockPinResult>();
  int lockCalls = 0;

  @override
  Future<AppLockStatus> status() async => const AppLockStatus.ready();

  @override
  Future<AppLockEnrollmentResult> enroll(String pin) async =>
      const AppLockEnrollmentResult.provisioned();

  @override
  Future<AppLockPinResult> verifyPin(String pin) => this.pin.future;

  @override
  Future<AppLockBiometricResult> verifyBiometric() async =>
      const AppLockBiometricResult.cancelled();

  @override
  Future<void> lockNativeBridge() async {
    lockCalls++;
  }

  @override
  Future<void> unlockNativeBridge() async {}
}

final class _CooldownPort implements AppLockPort {
  _CooldownPort({List<AppLockPinResult>? results})
    : _results =
          results ??
          <AppLockPinResult>[
            AppLockPinResult.cooldown(DateTime.utc(2026, 8, 30, 10, 1)),
            const AppLockPinResult.unlocked(),
          ];

  final List<AppLockPinResult> _results;
  int attempts = 0;
  int lockCalls = 0;

  @override
  Future<AppLockStatus> status() async => const AppLockStatus.ready();

  @override
  Future<AppLockEnrollmentResult> enroll(String pin) async =>
      const AppLockEnrollmentResult.provisioned();

  @override
  Future<AppLockPinResult> verifyPin(String pin) async {
    return _results[attempts++];
  }

  @override
  Future<AppLockBiometricResult> verifyBiometric() async =>
      const AppLockBiometricResult.cancelled();

  @override
  Future<void> lockNativeBridge() async {
    lockCalls++;
  }

  @override
  Future<void> unlockNativeBridge() async {}
}

final class _TimerFactory {
  final List<void Function()> callbacks = <void Function()>[];
  bool cancelled = false;

  AppLockTimer call(Duration delay, void Function() callback) {
    callbacks.add(callback);
    return _FakeTimer(() => cancelled = true);
  }

  void fire(int index) => callbacks[index]();
}

final class _FakeTimer implements AppLockTimer {
  _FakeTimer(this._onCancel);

  final void Function() _onCancel;

  @override
  void cancel() => _onCancel();
}
