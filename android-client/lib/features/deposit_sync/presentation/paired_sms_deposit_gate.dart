import 'dart:async';

import 'package:flutter/material.dart';

import '../../pairing/presentation/pairing_protocol_bloc.dart';
import '../../sms_gateway/domain/sms_gateway.dart';
import '../data/encrypted_sms_release_store.dart';
import '../domain/signed_sms_deposit_parser.dart';
import 'deposit_submission_runtime.dart';
import 'sms_deposit_coordinator.dart';

/// Mounted by the permission gate only inside the unlocked view. Pairing
/// activation includes the final authenticated server acknowledgement.
final class PairedSmsDepositGate extends StatefulWidget {
  const PairedSmsDepositGate({super.key, required this.pairing,
    required this.gateway, required this.builder});
  final PairingProtocolBloc? pairing;
  final SmsGatewayPort gateway;
  final Widget Function(SmsDepositCoordinator?, bool unavailable) builder;

  @override
  State<PairedSmsDepositGate> createState() => _PairedSmsDepositGateState();
}

final class _PairedSmsDepositGateState extends State<PairedSmsDepositGate> {
  StreamSubscription<PairingProtocolState>? _pairingSubscription;
  Timer? _retry;
  SmsDepositCoordinator? _coordinator;
  DepositSubmissionRuntime? _runtime;
  EncryptedSmsReleaseStore? _releases;
  bool _creating = false;
  bool _unavailable = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _pairingSubscription = widget.pairing?.stream.listen(_pairingChanged);
    _pairingChanged(widget.pairing?.state ?? const PairingProtocolIdle());
  }

  void _pairingChanged(PairingProtocolState state) {
    if (state is PairingProtocolActivated) {
      unawaited(_create());
    } else {
      _generation++;
      _retry?.cancel();
      _retry = null;
      final SmsDepositCoordinator? coordinator = _coordinator;
      final DepositSubmissionRuntime? runtime = _runtime;
      final EncryptedSmsReleaseStore? releases = _releases;
      _coordinator = null;
      _runtime = null;
      _releases = null;
      if (coordinator != null) unawaited(_closeResources(coordinator, runtime, releases));
      if (mounted) setState(() {});
    }
  }

  Future<void> _create() async {
    if (_creating || _coordinator != null || !mounted) return;
    _creating = true;
    final int generation = _generation;
    DepositSubmissionRuntime? runtime;
    EncryptedSmsReleaseStore? releases;
    try {
      releases = await EncryptedSmsReleaseStore.open(
        verifier: const SignedSmsDepositReleaseVerifier(
          pinnedSigningPublicKey: String.fromEnvironment('OPENPAY_OPERATOR_PATTERN_SIGNING_PUBLIC_KEY')));
      runtime = await DepositSubmissionRuntime.createPairedMobileEnvelope();
      if (!mounted || generation != _generation) {
        await runtime.close();
        await releases.close();
        return;
      }
      final SmsDepositCoordinator coordinator = SmsDepositCoordinator(
        gateway: widget.gateway, releases: releases, submissions: runtime.bloc);
      _runtime = runtime;
      _releases = releases;
      setState(() { _coordinator = coordinator; _unavailable = false; });
      _retry = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(coordinator.sync()));
      await coordinator.sync();
    } on Object {
      if (_runtime != runtime) await runtime?.close();
      if (_releases != releases) await releases?.close();
      if (mounted && generation == _generation) setState(() => _unavailable = true);
    } finally {
      _creating = false;
      if (mounted && generation != _generation && _coordinator == null &&
          widget.pairing?.state is PairingProtocolActivated) {
        unawaited(_create());
      }
    }
  }

  Future<void> _closeResources(SmsDepositCoordinator? coordinator,
    DepositSubmissionRuntime? runtime, EncryptedSmsReleaseStore? releases) async {
    await coordinator?.close();
    await runtime?.close();
    await releases?.close();
  }

  @override
  void dispose() {
    _generation++;
    _retry?.cancel();
    unawaited(_pairingSubscription?.cancel() ?? Future<void>.value());
    unawaited(_closeResources(_coordinator, _runtime, _releases));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_coordinator, _unavailable);
}
