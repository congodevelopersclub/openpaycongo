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

  test('startup restores native-confirmed pairing and can activate it', () async {
    final _ActivationRequest request = _ActivationRequest();
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: _Protocol(),
      activation: const _Activation(PairingActivationOutcome.activated),
      acknowledgement: _Acknowledgement.acknowledged(),
      recovery: _Recovery(
        PairingRecoveredMaterial(
          serverSas: '482901',
          activationRequest: request,
        ),
      ),
    );
    addTearDown(bloc.close);

    final Future<PairingProtocolState> restored = bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolAwaitingConfirmation,
    );
    await bloc.restore();

    expect(await restored, isA<PairingProtocolAwaitingConfirmation>());
    expect(bloc.state, isA<PairingProtocolAwaitingConfirmation>());
    bloc.add(const PairingActivationRequested());
    await bloc.stream.firstWhere((PairingProtocolState state) => state is PairingProtocolActivated);
    expect(request.disposed, isTrue);
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
      acknowledgement: _Acknowledgement.acknowledged(),
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

  test('activation retains its exchange and disposes a replacement QR command', () async {
    final _ActivationRequest request = _ActivationRequest();
    final _Protocol protocol = _Protocol(activationRequest: request);
    final _DeferredActivation activation = _DeferredActivation();
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: protocol,
      activation: activation,
      acknowledgement: _Acknowledgement.acknowledged(),
    );
    addTearDown(bloc.close);
    bloc.add(const PairingProtocolStarted(_Command()));
    await bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolAwaitingConfirmation,
    );

    bloc.add(const PairingActivationRequested());
    await activation.started.future;
    final _TrackedCommand replacement = _TrackedCommand();
    bloc.add(PairingProtocolStarted(replacement));
    await Future<void>.delayed(Duration.zero);

    expect(protocol.calls, 1);
    expect(replacement.disposed, isTrue);
    expect(request.disposed, isFalse);
    final Future<PairingProtocolState> activated = bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolActivated,
    );
    activation.complete(PairingActivationOutcome.activated);
    expect(await activated, isA<PairingProtocolActivated>());
    expect(request.disposed, isTrue);
  });

  test('keeps native-installed pairing pending until its encrypted acknowledgement succeeds', () async {
    final _ActivationRequest request = _ActivationRequest();
    final _Acknowledgement acknowledgement = _Acknowledgement(<PairingActivationAcknowledgementOutcome>[
      PairingActivationAcknowledgementOutcome.retryable,
      PairingActivationAcknowledgementOutcome.acknowledged,
    ]);
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: _Protocol(activationRequest: request),
      activation: const _Activation(PairingActivationOutcome.activated),
      acknowledgement: acknowledgement,
    );
    addTearDown(bloc.close);

    bloc.add(const PairingProtocolStarted(_Command()));
    await bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolAwaitingConfirmation,
    );
    bloc.add(const PairingActivationRequested());
    await bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolActivationAcknowledgementPending,
    );
    expect(request.disposed, isTrue);

    bloc.add(const PairingActivationAcknowledgementRequested());
    await bloc.stream.firstWhere((PairingProtocolState state) => state is PairingProtocolActivated);
    expect(acknowledgement.calls, 2);
  });

  test('startup resumes a durable pending acknowledgement without restoring QR data', () async {
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: _Protocol(),
      acknowledgement: _Acknowledgement(
        <PairingActivationAcknowledgementOutcome>[
          PairingActivationAcknowledgementOutcome.acknowledged,
        ],
        recovery: PairingActivationAcknowledgementRecovery.pending,
      ),
    );
    addTearDown(bloc.close);

    await bloc.restore();
    expect(bloc.state, isA<PairingProtocolActivationAcknowledgementPending>());

    bloc.add(const PairingActivationAcknowledgementRequested());
    await bloc.stream.firstWhere((PairingProtocolState state) => state is PairingProtocolActivated);
  });

  test('startup publishes active only from native durable acknowledgement state', () async {
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: _Protocol(),
      acknowledgement: _Acknowledgement(
        <PairingActivationAcknowledgementOutcome>[
          PairingActivationAcknowledgementOutcome.acknowledged,
        ],
        recovery: PairingActivationAcknowledgementRecovery.active,
      ),
    );
    addTearDown(bloc.close);

    await bloc.restore();

    expect(bloc.state, isA<PairingProtocolActivated>());
  });

  test('startup resumes a confirmed replacement before an older active pairing', () async {
    final _ActivationRequest replacement = _ActivationRequest();
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: _Protocol(),
      acknowledgement: _Acknowledgement(
        <PairingActivationAcknowledgementOutcome>[
          PairingActivationAcknowledgementOutcome.acknowledged,
        ],
        recovery: PairingActivationAcknowledgementRecovery.active,
      ),
      recovery: _Recovery(
        PairingRecoveredMaterial(
          serverSas: '482901',
          activationRequest: replacement,
        ),
      ),
    );
    addTearDown(bloc.close);

    await bloc.restore();

    expect(bloc.state, isA<PairingProtocolAwaitingConfirmation>());
    expect((bloc.state as PairingProtocolAwaitingConfirmation).sas, '482901');
    expect(replacement.disposed, isFalse);
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

final class _Recovery implements PairingRecoveryPort {
  const _Recovery(this.material);
  final PairingRecoveredMaterial? material;

  @override
  Future<PairingRecoveredMaterial?> restore() async => material;
}

final class _DeferredActivation implements PairingActivationPort {
  final Completer<void> started = Completer<void>();
  final Completer<PairingActivationOutcome> _result = Completer<PairingActivationOutcome>();

  @override
  Future<PairingActivationOutcome> activate(PairingActivationRequest request) {
    started.complete();
    return _result.future;
  }

  void complete(PairingActivationOutcome outcome) => _result.complete(outcome);
}

final class _Acknowledgement implements PairingActivationAcknowledgementPort {
  _Acknowledgement(this.outcomes, {this.recovery = PairingActivationAcknowledgementRecovery.none});

  factory _Acknowledgement.acknowledged() => _Acknowledgement(<PairingActivationAcknowledgementOutcome>[
    PairingActivationAcknowledgementOutcome.acknowledged,
  ]);

  final List<PairingActivationAcknowledgementOutcome> outcomes;
  final PairingActivationAcknowledgementRecovery recovery;
  var calls = 0;

  @override
  Future<PairingActivationAcknowledgementOutcome> acknowledge() async {
    final int index = calls < outcomes.length ? calls : outcomes.length - 1;
    calls += 1;
    return outcomes[index];
  }

  @override
  Future<PairingActivationAcknowledgementRecovery> restore() async => recovery;
}
