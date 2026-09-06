import 'dart:async';

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

/// Native-owned acknowledgement bridge. It exposes only redacted state.
abstract interface class PairingActivationAcknowledgementPort {
  Future<PairingActivationAcknowledgementOutcome> acknowledge();

  Future<PairingActivationAcknowledgementRecovery> restore();
}

enum PairingActivationAcknowledgementOutcome { acknowledged, retryable, recoveryRequired }

enum PairingActivationAcknowledgementRecovery { none, pending, active, recoveryRequired }

abstract interface class PairingActivationRequest {
  void dispose();
}

/// Startup-only native recovery boundary. It returns redacted SAS plus an
/// opaque activation request; pairing keys and credentials stay native.
abstract interface class PairingRecoveryPort {
  Future<PairingRecoveredMaterial?> restore();
}

final class PairingRecoveredMaterial {
  PairingRecoveredMaterial({
    required this.serverSas,
    required this.activationRequest,
  });

  final String serverSas;
  PairingActivationRequest? activationRequest;

  void dispose() {
    activationRequest?.dispose();
    activationRequest = null;
  }
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

/// App-unlocked startup requests native recovery through normal BLoC flow.
final class PairingProtocolRecoveryRequested extends PairingProtocolEvent {
  PairingProtocolRecoveryRequested(this.completion);

  final Completer<void> completion;
}

/// UI sends only confirmation progression; no credential/key/envelope fields.
final class PairingActivationRequested extends PairingProtocolEvent {
  const PairingActivationRequested();
}

/// Retries only the encrypted final acknowledgement; no QR or key data returns.
final class PairingActivationAcknowledgementRequested extends PairingProtocolEvent {
  const PairingActivationAcknowledgementRequested();
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

/// Activation envelope is durable, but the server has not yet authenticated its receipt.
final class PairingProtocolActivationAcknowledgementPending extends PairingProtocolState {
  const PairingProtocolActivationAcknowledgementPending();
}

final class PairingProtocolRecoveryRequired extends PairingProtocolState {
  const PairingProtocolRecoveryRequired();
}

final class PairingProtocolBloc
    extends Bloc<PairingProtocolEvent, PairingProtocolState> {
  PairingProtocolBloc({
    required this.protocol,
    PairingActivationPort? activation,
    PairingActivationAcknowledgementPort? acknowledgement,
    PairingRecoveryPort? recovery,
  })
    : activation = activation ?? const _UnavailableActivationPort(),
      acknowledgement = acknowledgement ?? const _UnavailableAcknowledgementPort(),
      recovery = recovery ?? const _UnavailableRecoveryPort(),
      super(const PairingProtocolIdle()) {
    on<PairingProtocolStarted>(_start);
    on<PairingProtocolRecoveryRequested>(_restore);
    on<PairingActivationRequested>(_activate);
    on<PairingActivationAcknowledgementRequested>(_acknowledge);
  }

  final PairingProtocolPort protocol;
  final PairingActivationPort activation;
  final PairingActivationAcknowledgementPort acknowledgement;
  final PairingRecoveryPort recovery;
  var _startActive = false;
  var _activationActive = false;
  PairingActivationRequest? _activationRequest;

  Future<void> restore() {
    if (isClosed) return Future<void>.value();
    final Completer<void> completion = Completer<void>();
    add(PairingProtocolRecoveryRequested(completion));
    return completion.future;
  }

  Future<void> _restore(
    PairingProtocolRecoveryRequested event,
    Emitter<PairingProtocolState> emit,
  ) async {
    if (_startActive || _activationActive || state is! PairingProtocolIdle) {
      event.completion.complete();
      return;
    }
    PairingRecoveredMaterial? material;
    try {
      material = await recovery.restore();
      if (material != null) {
        if (state is! PairingProtocolIdle) return;
        final PairingActivationRequest? request = material.activationRequest;
        if (request == null || !RegExp(r'^[0-9]{6}$').hasMatch(material.serverSas)) {
          material.dispose();
          emit(const PairingProtocolRecoveryRequired());
          return;
        }
        material.activationRequest = null;
        _activationRequest = request;
        emit(PairingProtocolAwaitingConfirmation(material.serverSas));
        return;
      }
      final PairingActivationAcknowledgementRecovery acknowledgementRecovery =
          await acknowledgement.restore();
      if (acknowledgementRecovery == PairingActivationAcknowledgementRecovery.pending) {
        emit(const PairingProtocolActivationAcknowledgementPending());
        return;
      }
      if (acknowledgementRecovery == PairingActivationAcknowledgementRecovery.active) {
        emit(const PairingProtocolActivated());
        return;
      }
      if (acknowledgementRecovery == PairingActivationAcknowledgementRecovery.recoveryRequired) {
        emit(const PairingProtocolRecoveryRequired());
        return;
      }
    } on Object {
      emit(const PairingProtocolRecoveryRequired());
    } finally {
      material?.dispose();
      if (!event.completion.isCompleted) event.completion.complete();
    }
  }

  Future<void> _start(
    PairingProtocolStarted event,
    Emitter<PairingProtocolState> emit,
  ) async {
    if (_startActive ||
        _activationActive ||
        state is PairingProtocolAwaitingConfirmation ||
        state is PairingProtocolActivating ||
        state is PairingProtocolActivationAcknowledgementPending) {
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
        await _finishAcknowledgement(emit);
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

  Future<void> _acknowledge(
    PairingActivationAcknowledgementRequested event,
    Emitter<PairingProtocolState> emit,
  ) async {
    if (_activationActive || state is! PairingProtocolActivationAcknowledgementPending) return;
    _activationActive = true;
    emit(const PairingProtocolActivating());
    try {
      await _finishAcknowledgement(emit);
    } finally {
      _activationActive = false;
    }
  }

  Future<void> _finishAcknowledgement(Emitter<PairingProtocolState> emit) async {
    final PairingActivationAcknowledgementOutcome outcome = await acknowledgement.acknowledge();
    switch (outcome) {
      case PairingActivationAcknowledgementOutcome.acknowledged:
        emit(const PairingProtocolActivated());
      case PairingActivationAcknowledgementOutcome.retryable:
        emit(const PairingProtocolActivationAcknowledgementPending());
      case PairingActivationAcknowledgementOutcome.recoveryRequired:
        emit(const PairingProtocolRecoveryRequired());
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

final class _UnavailableRecoveryPort implements PairingRecoveryPort {
  const _UnavailableRecoveryPort();

  @override
  Future<PairingRecoveredMaterial?> restore() async => null;
}

final class _UnavailableAcknowledgementPort implements PairingActivationAcknowledgementPort {
  const _UnavailableAcknowledgementPort();

  @override
  Future<PairingActivationAcknowledgementOutcome> acknowledge() async =>
      PairingActivationAcknowledgementOutcome.recoveryRequired;

  @override
  Future<PairingActivationAcknowledgementRecovery> restore() async =>
      PairingActivationAcknowledgementRecovery.none;
}
