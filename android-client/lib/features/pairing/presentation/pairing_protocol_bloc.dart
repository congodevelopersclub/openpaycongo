import 'package:flutter_bloc/flutter_bloc.dart';

import 'pairing_v2_crypto.dart';

/// Implemented with libsodium `crypto_kx` and XChaCha20-Poly1305. Wire shape
/// remains transport-owned until revised server contract fixtures land.
abstract interface class PairingProtocolPort {
  Future<PairingPendingMaterial> establish(PairingProtocolCommand command);
}

/// Opaque infrastructure handle. Its implementation owns QR secret lifetime.
/// Opaque command owns any short-lived QR-derived secret bytes.
abstract interface class PairingProtocolCommand {
  /// Idempotent. Called after success, failure, or a rejected handoff.
  void dispose();
}

/// Android implementation encrypts these directional keys with a
/// non-exportable Android Keystore key. No BLoC state may retain them.
abstract interface class PairingDirectionalKeyVault {
  /// Copy both keys to Android Keystore-backed storage before completing.
  /// Caller wipes [keys] immediately after this future completes or fails.
  Future<void> save(PairingDirectionalKeys keys);
}

/// Opaque activation request. Its routing bytes never enter BLoC state.
abstract interface class PairingActivationPort {
  Future<PairingActivationOutcome> activate(PairingActivationRequest request);
}

enum PairingActivationOutcome { activated, recoveryRequired }

abstract interface class PairingActivationRequest {
  void dispose();
}

final class PairingPendingMaterial {
  PairingPendingMaterial({
    required this.serverSas,
    required this.keys,
    this.activationRequest,
    required this._onDispose,
  });

  final String serverSas;
  final PairingDirectionalKeys keys;
  PairingActivationRequest? activationRequest;
  final void Function() _onDispose;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    keys.dispose();
    activationRequest?.dispose();
    activationRequest = null;
    _onDispose();
  }
}

sealed class PairingProtocolEvent {
  const PairingProtocolEvent();
}

final class PairingProtocolStarted extends PairingProtocolEvent {
  const PairingProtocolStarted(this.command);

  final PairingProtocolCommand command;
}

/// UI sends only confirmation progression; no credential/key/envelope fields.
final class PairingActivationRequested extends PairingProtocolEvent {
  const PairingActivationRequested();
}

sealed class PairingProtocolState {
  const PairingProtocolState();
}

final class PairingProtocolIdle extends PairingProtocolState {
  const PairingProtocolIdle();
}

/// One encrypted completion is in flight. Another QR must wait for recovery
/// or the authenticated administrator-confirmation result.
final class PairingProtocolEstablishing extends PairingProtocolState {
  const PairingProtocolEstablishing();
}

/// Server-issued SAS only. Pairing activates only after server confirmation.
final class PairingProtocolAwaitingConfirmation extends PairingProtocolState {
  const PairingProtocolAwaitingConfirmation(this.sas);

  final String sas;
}

final class PairingProtocolActivating extends PairingProtocolState {
  const PairingProtocolActivating();
}

final class PairingProtocolActivated extends PairingProtocolState {
  const PairingProtocolActivated();
}

final class PairingProtocolRecoveryRequired extends PairingProtocolState {
  const PairingProtocolRecoveryRequired();
}

final class PairingProtocolBloc
    extends Bloc<PairingProtocolEvent, PairingProtocolState> {
  PairingProtocolBloc({required this.protocol, required this.vault, PairingActivationPort? activation})
    : activation = activation ?? const _UnavailableActivationPort(),
      super(const PairingProtocolIdle()) {
    on<PairingProtocolStarted>(_start);
    on<PairingActivationRequested>(_activate);
  }

  final PairingProtocolPort protocol;
  final PairingDirectionalKeyVault vault;
  final PairingActivationPort activation;
  var _startActive = false;
  var _activationActive = false;
  PairingActivationRequest? _activationRequest;

  Future<void> _start(
    PairingProtocolStarted event,
    Emitter<PairingProtocolState> emit,
  ) async {
    if (_startActive || state is PairingProtocolAwaitingConfirmation) {
      event.command.dispose();
      return;
    }
    _startActive = true;
    emit(const PairingProtocolEstablishing());
    PairingPendingMaterial? material;
    try {
      material = await protocol.establish(event.command);
      await vault.save(material.keys);
      _activationRequest?.dispose();
      _activationRequest = material.activationRequest;
      material.activationRequest = null;
      emit(PairingProtocolAwaitingConfirmation(material.serverSas));
    } on Object {
      emit(const PairingProtocolRecoveryRequired());
    } finally {
      material?.dispose();
      event.command.dispose();
      _startActive = false;
    }
  }

  Future<void> _activate(
    PairingActivationRequested event,
    Emitter<PairingProtocolState> emit,
  ) async {
    final PairingActivationRequest? request = _activationRequest;
    if (_activationActive || state is! PairingProtocolAwaitingConfirmation || request == null) return;
    _activationActive = true;
    _activationRequest = null;
    emit(const PairingProtocolActivating());
    try {
      final PairingActivationOutcome outcome = await activation.activate(request);
      if (outcome == PairingActivationOutcome.activated) {
        emit(const PairingProtocolActivated());
      } else {
        emit(const PairingProtocolRecoveryRequired());
      }
    } on Object {
      emit(const PairingProtocolRecoveryRequired());
    } finally {
      request.dispose();
      _activationActive = false;
    }
  }

  @override
  Future<void> close() {
    _activationRequest?.dispose();
    _activationRequest = null;
    return super.close();
  }
}

final class _UnavailableActivationPort implements PairingActivationPort {
  const _UnavailableActivationPort();

  @override
  Future<PairingActivationOutcome> activate(PairingActivationRequest request) async =>
      PairingActivationOutcome.recoveryRequired;
}
