import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/presentation/payment_inbox_bloc.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';

void main() {
  test(
    'decision uncertainty stays unknown when authority reload fails',
    () async {
      final PaymentInboxBloc bloc = PaymentInboxBloc(
        gateway: _Gateway(failCommit: true, failReload: true),
      );
      addTearDown(bloc.close);

      bloc.add(const PaymentInboxStarted());
      await bloc.stream.firstWhere((PaymentInboxState state) => state.ready);

      bloc.add(
        const PaymentInboxDecisionRequested(
          recordId: 'synthetic-record',
          decision: NativeCaptureDecision.reviewed,
        ),
      );

      final PaymentInboxState state = await bloc.stream.firstWhere(
        (PaymentInboxState state) =>
            state.feedback == PaymentInboxFeedback.decisionReloadFailed,
      );
      expect(state.authority, PaymentInboxAuthority.unknown);
      expect(state.records, isEmpty);
    },
  );

  test(
    'rule mutation uncertainty stays unknown when authority reload fails',
    () async {
      final PaymentInboxBloc bloc = PaymentInboxBloc(
        gateway: _Gateway(failCommit: false, failReload: true, failAdd: true),
      );
      addTearDown(bloc.close);
      bloc.add(const PaymentInboxStarted());
      await bloc.stream.firstWhere((PaymentInboxState state) => state.ready);

      bloc.add(
        const PaymentInboxTrustedSenderSaveRequested(
          sender: 'TEST',
          template: '{amount} {currency} {reference}',
        ),
      );
      final PaymentInboxState state = await bloc.stream.firstWhere(
        (PaymentInboxState state) =>
            state.feedback == PaymentInboxFeedback.ruleAddReloadFailed,
      );
      expect(state.authority, PaymentInboxAuthority.unknown);
    },
  );

  test(
    'does not start a second trusted-rule mutation before first resolves',
    () async {
      final Completer<void> addGate = Completer<void>();
      final _Gateway gateway = _Gateway(
        failCommit: false,
        failReload: false,
        addGate: addGate,
      );
      final PaymentInboxBloc bloc = PaymentInboxBloc(gateway: gateway);
      addTearDown(bloc.close);
      bloc.add(const PaymentInboxStarted());
      await bloc.stream.firstWhere((PaymentInboxState state) => state.ready);

      bloc.add(
        const PaymentInboxTrustedSenderSaveRequested(
          sender: 'TEST',
          template: '{amount} {currency} {reference}',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(gateway.addCalls, 1);

      bloc.add(const PaymentInboxTrustedSendersCleared());
      await Future<void>.delayed(Duration.zero);
      expect(gateway.clearCalls, 0);

      addGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.clearCalls, 1);
    },
  );

  test(
    'rule save stays unknown after initial and reconciliation reload fail',
    () async {
      final PaymentInboxBloc bloc = PaymentInboxBloc(
        gateway: _Gateway(
          failCommit: false,
          failReload: true,
          failInitialReload: true,
        ),
      );
      addTearDown(bloc.close);

      bloc.add(const PaymentInboxStarted());
      await bloc.stream.firstWhere((PaymentInboxState state) => state.ready);
      expect(bloc.state.authority, PaymentInboxAuthority.unknown);

      bloc.add(
        const PaymentInboxTrustedSenderSaveRequested(
          sender: 'TEST',
          template: '{amount} {currency} {reference}',
        ),
      );
      final PaymentInboxState state = await bloc.stream.firstWhere(
        (PaymentInboxState state) =>
            state.feedback == PaymentInboxFeedback.ruleSaved ||
            state.feedback == PaymentInboxFeedback.ruleAddReloadFailed,
      );

      expect(state.authority, PaymentInboxAuthority.unknown);
      expect(state.records, isEmpty);
    },
  );
}

final class _Gateway implements SmsGatewayPort {
  _Gateway({
    required this.failCommit,
    required this.failReload,
    this.failAdd = false,
    this.addGate,
    this.failInitialReload = false,
  });

  final bool failCommit;
  final bool failReload;
  final bool failAdd;
  final Completer<void>? addGate;
  final bool failInitialReload;
  int _listCalls = 0;
  int addCalls = 0;
  int clearCalls = 0;

  @override
  Future<NativeCaptureHealth> captureHealth() async =>
      const NativeCaptureHealth(fault: null);

  @override
  Future<List<NativeSmsRecord>> drainInbox() async => <NativeSmsRecord>[
    NativeSmsRecord(
      id: 'synthetic-record',
      sender: 'TEST',
      receivedAt: DateTime.utc(2026),
      segments: 1,
      body: 'synthetic',
    ),
  ];

  @override
  Future<List<String>> listTrustedSenders() async {
    _listCalls += 1;
    if ((failInitialReload && _listCalls == 1) ||
        (failReload && _listCalls > 1)) {
      throw StateError('unavailable');
    }
    return const <String>[];
  }

  @override
  Future<void> commitInboxDecision(
    String id,
    NativeCaptureDecision decision,
  ) async {
    if (failCommit) throw StateError('unavailable');
  }

  @override
  Future<List<String>> addTrustedSender(String sender) async {
    addCalls += 1;
    await addGate?.future;
    if (failAdd) throw StateError('unavailable');
    return const <String>[];
  }

  @override
  Future<List<String>> clearTrustedSenders() async {
    clearCalls += 1;
    return const <String>[];
  }

  @override
  Future<NativeDecisionPage> exportDecisions({
    int limit = 100,
    String? cursor,
  }) async => const NativeDecisionPage(
    records: <NativeDecisionRecord>[],
    nextCursor: null,
    truncated: false,
  );
  @override
  Future<SmsAccessState> permissionState() async => SmsAccessState.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<bool> probeStorage() async => true;
  @override
  Future<SmsAccessState> requestPermission() async => SmsAccessState.granted;
  @override
  Future<List<String>> revokeTrustedSender(String sender) async =>
      const <String>[];
  @override
  Future<int> accessGeneration() async => 1;
  @override
  Future<void> setUnlocked(bool unlocked, {int? generation}) async {}
}
