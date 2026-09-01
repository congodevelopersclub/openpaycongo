import 'package:flutter_bloc/flutter_bloc.dart';

/// Pairing crypto owns directional keys behind a platform boundary. BLoC owns
/// only redacted flow state and never receives key material.
abstract interface class PairingProtocolPort {
  Future<PairingPendingMaterial> establish(PairingProtocolCommand command);
}

/// Opaque infrastructure handle. Its implementation owns QR secret lifetime.
/// Opaque command owns any short-lived QR-derived secret bytes.
abstract interface class PairingProtocolCommand {
  /// Idempotent. Called after success, failure, or a rejected handoff.
  void dispose();
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
    this.activationRequest,
    required this._onDispose,
  });

  final String serverSas;
  PairingActivationRequest? activationRequest;
  final void Function() _onDispose;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
  PairingProtocolBloc({required this.protocol, PairingActivationPort? activation})
    : activation = activation ?? const _UnavailableActivationPort(),
      super(const PairingProtocolIdle()) {
    on<PairingProtocolStarted>(_start);
    on<PairingActivationRequested>(_activate);
  }

  final PairingProtocolPort protocol;
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
