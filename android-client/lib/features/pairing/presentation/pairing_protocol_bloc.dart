import 'package:flutter_bloc/flutter_bloc.dart';

import 'pairing_v2_crypto.dart';

/// Implemented with libsodium `crypto_kx` and XChaCha20-Poly1305. Wire shape
/// remains transport-owned until revised server contract fixtures land.
abstract interface class PairingProtocolPort {
  Future<PairingPendingMaterial> establish(PairingProtocolCommand command);
}

/// Opaque infrastructure handle. Its implementation owns QR secret lifetime.
abstract interface class PairingProtocolCommand {}

/// Android implementation encrypts these directional keys with a
/// non-exportable Android Keystore key. No BLoC state may retain them.
abstract interface class PairingDirectionalKeyVault {
  /// Copy both keys to Android Keystore-backed storage before completing.
  /// Caller wipes [keys] immediately after this future completes or fails.
  Future<void> save(PairingDirectionalKeys keys);
}

final class PairingPendingMaterial {
  PairingPendingMaterial({
    required this.serverSas,
    required this.keys,
    required this._onDispose,
  });

  final String serverSas;
  final PairingDirectionalKeys keys;
  final void Function() _onDispose;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    keys.dispose();
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

sealed class PairingProtocolState {
  const PairingProtocolState();
}

final class PairingProtocolIdle extends PairingProtocolState {
  const PairingProtocolIdle();
}

/// Server-issued SAS only. Pairing activates only after server confirmation.
final class PairingProtocolAwaitingConfirmation extends PairingProtocolState {
  const PairingProtocolAwaitingConfirmation(this.sas);

  final String sas;
}

final class PairingProtocolRecoveryRequired extends PairingProtocolState {
  const PairingProtocolRecoveryRequired();
}

final class PairingProtocolBloc
    extends Bloc<PairingProtocolEvent, PairingProtocolState> {
  PairingProtocolBloc({required this.protocol, required this.vault})
    : super(const PairingProtocolIdle()) {
    on<PairingProtocolStarted>(_start);
  }

  final PairingProtocolPort protocol;
  final PairingDirectionalKeyVault vault;

  Future<void> _start(
    PairingProtocolStarted event,
    Emitter<PairingProtocolState> emit,
  ) async {
    PairingPendingMaterial? material;
    try {
      material = await protocol.establish(event.command);
      await vault.save(material.keys);
      emit(PairingProtocolAwaitingConfirmation(material.serverSas));
    } on Object {
      emit(const PairingProtocolRecoveryRequired());
    } finally {
      material?.dispose();
    }
  }
}
