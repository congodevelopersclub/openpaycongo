import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../presentation/app_lock_bloc.dart';

/// Android method-channel adapter. Native storage owns all verifier material;
/// this adapter decodes only small typed outcomes and never logs PINs.
final class PlatformAppLockPort implements AppLockPort {
  const PlatformAppLockPort()
    : _lockChannel = const MethodChannel('openpaycongo/app_lock'),
      _smsChannel = const MethodChannel('openpaycongo/sms_gateway'),
      _authentication = null;

  final MethodChannel _lockChannel;
  final MethodChannel _smsChannel;
  final LocalAuthentication? _authentication;

  @override
  Future<AppLockStatus> status() async {
    try {
      return switch (await _lockChannel.invokeMethod<String>('status')) {
        'enrollment_required' => const AppLockStatus.enrollmentRequired(),
        'ready' => const AppLockStatus.ready(),
        _ => const AppLockStatus.recoveryRequired(),
      };
    } on PlatformException {
      return const AppLockStatus.recoveryRequired();
    }
  }

  @override
  Future<AppLockEnrollmentResult> enroll(String pin) async {
    try {
      return switch (await _lockChannel.invokeMethod<String>('enroll', pin)) {
        'provisioned' => const AppLockEnrollmentResult.provisioned(),
        'ready' => const AppLockEnrollmentResult.provisioned(),
        'invalid' => const AppLockEnrollmentResult.invalid(),
        _ => const AppLockEnrollmentResult.recoveryRequired(),
      };
    } on PlatformException {
      return const AppLockEnrollmentResult.recoveryRequired();
    }
  }

  @override
  Future<AppLockPinResult> verifyPin(String pin) async {
    try {
      final Map<Object?, Object?>? outcome = await _lockChannel
          .invokeMethod<Map<Object?, Object?>>('verifyPin', pin);
      final Object? status = outcome?['status'];
      if (status == 'unlocked') return const AppLockPinResult.unlocked();
      if (status == 'rejected') return const AppLockPinResult.rejected();
      final Object? nextAttempt = outcome?['next_attempt_ms'];
      if (status == 'cooldown' && nextAttempt is int && nextAttempt >= 0) {
        return AppLockPinResult.cooldown(
          DateTime.fromMillisecondsSinceEpoch(nextAttempt, isUtc: true),
        );
      }
      return const AppLockPinResult.recoveryRequired();
    } on PlatformException {
      return const AppLockPinResult.recoveryRequired();
    }
  }

  @override
  Future<AppLockBiometricResult> verifyBiometric() async {
    try {
      final bool unlocked = await (_authentication ?? LocalAuthentication())
          .authenticate(
            localizedReason: 'Unlock OpenPay Congo to access payment content',
            biometricOnly: true,
            sensitiveTransaction: true,
            persistAcrossBackgrounding: false,
          );
      return unlocked
          ? const AppLockBiometricResult.unlocked()
          : const AppLockBiometricResult.cancelled();
    } on LocalAuthException {
      return const AppLockBiometricResult.unavailable();
    } on PlatformException {
      return const AppLockBiometricResult.unavailable();
    }
  }

  @override
  Future<void> lockNativeBridge() => _smsChannel.invokeMethod<void>(
    'setUnlocked',
    const <String, Object?>{'unlocked': false, 'generation': null},
  );

  @override
  Future<void> unlockNativeBridge() async {
    final int? generation = await _smsChannel.invokeMethod<int>(
      'accessGeneration',
    );
    if (generation == null || generation < 1) throw const FormatException();
    await _smsChannel.invokeMethod<void>('setUnlocked', <String, Object?>{
      'unlocked': true,
      'generation': generation,
    });
  }
}
