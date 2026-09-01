import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_protocol_bloc.dart';

void main() {
  test('BLoC accepts opaque protocol material and publishes only SAS', () async {
    final _Protocol protocol = _Protocol();
    final PairingProtocolBloc bloc = PairingProtocolBloc(protocol: protocol);
    addTearDown(bloc.close);
    final Future<PairingProtocolState> pending = bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolAwaitingConfirmation,
    );

    bloc.add(PairingProtocolStarted(const _Command()));

    final PairingProtocolAwaitingConfirmation state =
        await pending as PairingProtocolAwaitingConfirmation;
    expect(state.sas, '482901');
    expect(state.toString(), isNot(contains('key')));
    expect(protocol.calls, 1);
    expect(protocol.disposed, isTrue);
  });

  test('second command is disposed without protocol access', () async {
    final _DeferredProtocol protocol = _DeferredProtocol();
    final PairingProtocolBloc bloc = PairingProtocolBloc(protocol: protocol);
    addTearDown(bloc.close);
    final _TrackedCommand second = _TrackedCommand();
    bloc.add(const PairingProtocolStarted(_Command()));
    await protocol.started.future;
    bloc.add(PairingProtocolStarted(second));
    await Future<void>.delayed(Duration.zero);

    expect(protocol.calls, 1);
    expect(second.disposed, isTrue);
    protocol.complete();
  });

  test('activation receives opaque request and publishes redacted state', () async {
    final _ActivationRequest request = _ActivationRequest();
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: _Protocol(activationRequest: request),
      activation: const _Activation(PairingActivationOutcome.activated),
    );
    addTearDown(bloc.close);
    final Future<PairingProtocolState> activated = bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolActivated,
    );
    bloc.add(const PairingProtocolStarted(_Command()));
    await bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolAwaitingConfirmation,
    );
    bloc.add(const PairingActivationRequested());

    expect(await activated, isA<PairingProtocolActivated>());
    expect(request.disposed, isTrue);
    expect(bloc.state.toString(), isNot(contains('bearer')));
  });
}

final class _Command implements PairingProtocolCommand {
  const _Command();
  @override
  void dispose() {}
}

final class _TrackedCommand implements PairingProtocolCommand {
  var disposed = false;
  @override
  void dispose() => disposed = true;
}

final class _Protocol implements PairingProtocolPort {
  _Protocol({this.activationRequest});
  final PairingActivationRequest? activationRequest;
  var calls = 0;
  var disposed = false;
  @override
  Future<PairingPendingMaterial> establish(PairingProtocolCommand command) async {
    calls += 1;
    return PairingPendingMaterial(
      serverSas: '482901',
      activationRequest: activationRequest,
      onDispose: () => disposed = true,
    );
  }
}

final class _DeferredProtocol implements PairingProtocolPort {
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();
  var calls = 0;
  @override
  Future<PairingPendingMaterial> establish(PairingProtocolCommand command) async {
    calls += 1;
    started.complete();
    await _release.future;
    return PairingPendingMaterial(serverSas: '482901', onDispose: () {});
  }
  void complete() => _release.complete();
}

final class _ActivationRequest implements PairingActivationRequest {
  var disposed = false;
  @override
  void dispose() => disposed = true;
}

final class _Activation implements PairingActivationPort {
  const _Activation(this.outcome);
  final PairingActivationOutcome outcome;
  @override
  Future<PairingActivationOutcome> activate(PairingActivationRequest request) async => outcome;
}
