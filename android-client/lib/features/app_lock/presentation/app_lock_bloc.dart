import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

abstract interface class AppLockTimer {
  void cancel();
}

typedef AppLockTimerFactory =
    AppLockTimer Function(Duration delay, void Function() callback);

final class _DartAppLockTimer implements AppLockTimer {
  _DartAppLockTimer(Duration delay, void Function() callback)
    : _timer = Timer(delay, callback);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// The only boundary that can read, provision, or verify the native app-lock
/// verifier. PIN values never enter a state, log, or widget callback result.
abstract interface class AppLockPort {
  Future<AppLockStatus> status();
  Future<AppLockEnrollmentResult> enroll(String pin);
  Future<AppLockPinResult> verifyPin(String pin);
  Future<AppLockBiometricResult> verifyBiometric();
  Future<void> lockNativeBridge();
  Future<void> unlockNativeBridge();
}

enum AppLockStatusKind { enrollmentRequired, ready, recoveryRequired }

final class AppLockStatus {
  const AppLockStatus.ready() : kind = AppLockStatusKind.ready;
  const AppLockStatus.enrollmentRequired()
    : kind = AppLockStatusKind.enrollmentRequired;
  const AppLockStatus.recoveryRequired()
    : kind = AppLockStatusKind.recoveryRequired;

  final AppLockStatusKind kind;
}

enum AppLockEnrollmentKind { provisioned, invalid, recoveryRequired }

final class AppLockEnrollmentResult {
  const AppLockEnrollmentResult.provisioned()
    : kind = AppLockEnrollmentKind.provisioned;
  const AppLockEnrollmentResult.invalid()
    : kind = AppLockEnrollmentKind.invalid;
  const AppLockEnrollmentResult.recoveryRequired()
    : kind = AppLockEnrollmentKind.recoveryRequired;

  final AppLockEnrollmentKind kind;
}

enum AppLockPinKind { unlocked, rejected, cooldown, recoveryRequired }

final class AppLockPinResult {
  const AppLockPinResult.unlocked()
    : kind = AppLockPinKind.unlocked,
      nextAttemptAt = null;
  const AppLockPinResult.rejected()
    : kind = AppLockPinKind.rejected,
      nextAttemptAt = null;
  const AppLockPinResult.cooldown(this.nextAttemptAt)
    : kind = AppLockPinKind.cooldown;
  const AppLockPinResult.recoveryRequired()
    : kind = AppLockPinKind.recoveryRequired,
      nextAttemptAt = null;

  final AppLockPinKind kind;
  final DateTime? nextAttemptAt;
}

enum AppLockBiometricKind { unlocked, cancelled, unavailable, recoveryRequired }

final class AppLockBiometricResult {
  const AppLockBiometricResult.unlocked()
    : kind = AppLockBiometricKind.unlocked;
  const AppLockBiometricResult.cancelled()
    : kind = AppLockBiometricKind.cancelled;
  const AppLockBiometricResult.unavailable()
    : kind = AppLockBiometricKind.unavailable;
  const AppLockBiometricResult.recoveryRequired()
    : kind = AppLockBiometricKind.recoveryRequired;

  final AppLockBiometricKind kind;
}

enum AppLockLifecycle { background, resumed }

sealed class AppLockEvent {
  const AppLockEvent();
}

final class AppLockStarted extends AppLockEvent {
  const AppLockStarted();
}

final class AppLockEnrollmentSubmitted extends AppLockEvent {
  const AppLockEnrollmentSubmitted(this.pin, this.confirmation);

  final String pin;
  final String confirmation;
}

final class AppLockPinSubmitted extends AppLockEvent {
  const AppLockPinSubmitted(this.pin);

  final String pin;
}

final class AppLockBiometricRequested extends AppLockEvent {
  const AppLockBiometricRequested();
}

final class AppLockLifecycleChanged extends AppLockEvent {
  const AppLockLifecycleChanged(this.lifecycle);

  final AppLockLifecycle lifecycle;
}

final class _AppLockCooldownElapsed extends AppLockEvent {
  const _AppLockCooldownElapsed(this.generation, this.deadline);

  final int generation;
  final DateTime deadline;
}

sealed class AppLockBlocState {
  const AppLockBlocState();
}

final class AppLockStarting extends AppLockBlocState {
  const AppLockStarting();
}

final class AppLockEnrollmentRequired extends AppLockBlocState {
  const AppLockEnrollmentRequired({this.invalid = false});

  final bool invalid;
}

final class AppLockLocked extends AppLockBlocState {
  const AppLockLocked({this.cooldownUntil, this.biometricUnavailable = false});

  final DateTime? cooldownUntil;
  final bool biometricUnavailable;
}

final class AppLockPinVerifying extends AppLockBlocState {
  const AppLockPinVerifying();
}

final class AppLockBiometricVerifying extends AppLockBlocState {
  const AppLockBiometricVerifying();
}

final class AppLockUnlocked extends AppLockBlocState {
  const AppLockUnlocked();
}

final class AppLockRecoveryRequired extends AppLockBlocState {
  const AppLockRecoveryRequired();
}

/// Typed lifecycle owner. Only [AppLockUnlocked] can construct protected UI.
final class AppLockBloc extends Bloc<AppLockEvent, AppLockBlocState> {
  AppLockBloc({
    required this.port,
    DateTime Function()? now,
    AppLockTimerFactory? timer,
  }) : _now = now ?? DateTime.now,
       _timer = timer ?? _DartAppLockTimer.new,
       super(const AppLockStarting()) {
    on<AppLockStarted>(_start);
    on<AppLockEnrollmentSubmitted>(_enroll);
    on<AppLockPinSubmitted>(_verifyPin);
    on<AppLockBiometricRequested>(_verifyBiometric);
    on<AppLockLifecycleChanged>(_lifecycle);
    on<_AppLockCooldownElapsed>(_cooldownElapsed);
  }

  final AppLockPort port;
  final DateTime Function() _now;
  final AppLockTimerFactory _timer;
  int _generation = 0;
  int _cooldownGeneration = 0;
  AppLockTimer? _cooldownTimer;
  bool _closed = false;

  Future<void> _start(
    AppLockStarted event,
    Emitter<AppLockBlocState> emit,
  ) async {
    final int generation = ++_generation;
    try {
      final AppLockStatus status = await port.status();
      if (generation != _generation) return;
      switch (status.kind) {
        case AppLockStatusKind.enrollmentRequired:
          emit(const AppLockEnrollmentRequired());
        case AppLockStatusKind.ready:
          emit(const AppLockLocked());
        case AppLockStatusKind.recoveryRequired:
          _recovery(emit);
      }
    } on Object {
      if (generation == _generation) _recovery(emit);
    }
  }

  Future<void> _enroll(
    AppLockEnrollmentSubmitted event,
    Emitter<AppLockBlocState> emit,
  ) async {
    if (!_validPin(event.pin) || event.pin != event.confirmation) {
      emit(const AppLockEnrollmentRequired(invalid: true));
      return;
    }
    final int generation = ++_generation;
    try {
      final AppLockEnrollmentResult result = await port.enroll(event.pin);
      if (generation != _generation) return;
      switch (result.kind) {
        case AppLockEnrollmentKind.provisioned:
          emit(const AppLockLocked());
        case AppLockEnrollmentKind.invalid:
          emit(const AppLockEnrollmentRequired(invalid: true));
        case AppLockEnrollmentKind.recoveryRequired:
          _recovery(emit);
      }
    } on Object {
      if (generation == _generation) _recovery(emit);
    }
  }

  Future<void> _verifyPin(
    AppLockPinSubmitted event,
    Emitter<AppLockBlocState> emit,
  ) async {
    if (!_validPin(event.pin)) {
      emit(const AppLockLocked());
      return;
    }
    final int generation = ++_generation;
    emit(const AppLockPinVerifying());
    try {
      final AppLockPinResult result = await port.verifyPin(event.pin);
      if (generation != _generation) return;
      await _applyPin(result, emit, generation);
    } on Object {
      if (generation == _generation) _recovery(emit);
    }
  }

  Future<void> _applyPin(
    AppLockPinResult result,
    Emitter<AppLockBlocState> emit,
    int generation,
  ) async {
    switch (result.kind) {
      case AppLockPinKind.unlocked:
        await port.unlockNativeBridge();
        if (generation == _generation) emit(const AppLockUnlocked());
      case AppLockPinKind.rejected:
        emit(const AppLockLocked());
      case AppLockPinKind.cooldown:
        final DateTime? deadline = result.nextAttemptAt?.toUtc();
        if (deadline == null) {
          _recovery(emit);
          return;
        }
        _startCooldown(deadline);
        emit(AppLockLocked(cooldownUntil: deadline));
      case AppLockPinKind.recoveryRequired:
        _recovery(emit);
    }
  }

  Future<void> _verifyBiometric(
    AppLockBiometricRequested event,
    Emitter<AppLockBlocState> emit,
  ) async {
    final int generation = ++_generation;
    emit(const AppLockBiometricVerifying());
    try {
      final AppLockBiometricResult result = await port.verifyBiometric();
      if (generation != _generation) return;
      switch (result.kind) {
        case AppLockBiometricKind.unlocked:
          await port.unlockNativeBridge();
          if (generation == _generation) emit(const AppLockUnlocked());
        case AppLockBiometricKind.cancelled:
          emit(const AppLockLocked());
        case AppLockBiometricKind.unavailable:
          emit(const AppLockLocked(biometricUnavailable: true));
        case AppLockBiometricKind.recoveryRequired:
          _recovery(emit);
      }
    } on Object {
      if (generation == _generation) _recovery(emit);
    }
  }

  Future<void> _lifecycle(
    AppLockLifecycleChanged event,
    Emitter<AppLockBlocState> emit,
  ) async {
    if (event.lifecycle == AppLockLifecycle.resumed) return;
    ++_generation;
    _cancelCooldown();
    emit(const AppLockLocked());
    try {
      await port.lockNativeBridge();
    } on Object {
      // Native Activity lifecycle also locks before Flutter receives this event.
    }
  }

  bool _validPin(String pin) => RegExp(r'^[0-9]{6}$').hasMatch(pin);

  void _startCooldown(DateTime deadline) {
    _cancelCooldown();
    final Duration delay = deadline.difference(_now().toUtc());
    final int generation = ++_cooldownGeneration;
    _cooldownTimer = _timer(delay.isNegative ? Duration.zero : delay, () {
      if (!_closed && !isClosed) {
        add(_AppLockCooldownElapsed(generation, deadline));
      }
    });
  }

  void _cooldownElapsed(
    _AppLockCooldownElapsed event,
    Emitter<AppLockBlocState> emit,
  ) {
    final AppLockBlocState current = state;
    if (event.generation != _cooldownGeneration ||
        current is! AppLockLocked ||
        current.cooldownUntil != event.deadline) {
      return;
    }
    if (_now().toUtc().isBefore(event.deadline)) {
      _startCooldown(event.deadline);
      return;
    }
    _cancelCooldown();
    emit(const AppLockLocked());
  }

  void _cancelCooldown() {
    _cooldownGeneration++;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
  }

  void _recovery(Emitter<AppLockBlocState> emit) {
    _cancelCooldown();
    emit(const AppLockRecoveryRequired());
  }

  @override
  Future<void> close() {
    _closed = true;
    _cancelCooldown();
    return super.close();
  }
}
