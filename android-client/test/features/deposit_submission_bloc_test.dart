import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';

final class _Transport implements AuthenticatedDepositTransport {
  _Transport(this._results);

  final List<Future<DepositSubmissionResult> Function()> _results;
  final List<ProviderDeposit> submissions = <ProviderDeposit>[];

  @override
  Future<DepositSubmissionResult> submit(ProviderDeposit deposit) {
    submissions.add(deposit);
    return _results.removeAt(0)();
  }
}

final class _DelayedTransport implements AuthenticatedDepositTransport {
  final List<ProviderDeposit> submissions = <ProviderDeposit>[];
  final List<Completer<DepositSubmissionResult>> _responses =
      <Completer<DepositSubmissionResult>>[];

  @override
  Future<DepositSubmissionResult> submit(ProviderDeposit deposit) {
    submissions.add(deposit);
    final Completer<DepositSubmissionResult> response =
        Completer<DepositSubmissionResult>();
    _responses.add(response);
    return response.future;
  }

  void recorded(int index) =>
      _responses[index].complete(const DepositSubmissionResult.recorded());

  void unavailable(int index) =>
      _responses[index].completeError(const DepositTransportUnavailable());
}

const ProviderDeposit deposit = ProviderDeposit(
  customerLookupIdentifier: 'customer-private-001',
  providerReference: 'provider-private-001',
  amountMinor: 12500,
  currency: 'CDF',
  providerOccurredAt: '2026-08-31T01:00:00Z',
);

ProviderDeposit depositWithReference(String reference) => ProviderDeposit(
  customerLookupIdentifier: 'customer-$reference',
  providerReference: reference,
  amountMinor: 12500,
  currency: 'CDF',
  providerOccurredAt: '2026-08-31T01:00:00Z',
);

void main() {
  test('maps recorded, replayed, conflict, then retry-safe unavailable without exposing deposit data', () async {
    final _Transport transport = _Transport(<Future<DepositSubmissionResult> Function()>[
      () async => const DepositSubmissionResult.recorded(),
      () async => const DepositSubmissionResult.replayed(),
      () async => const DepositSubmissionResult.conflict(),
      () async => throw const DepositTransportUnavailable(),
      () async => const DepositSubmissionResult.replayed(),
    ]);
    final DepositSubmissionBloc bloc = DepositSubmissionBloc(transport: transport);
    addTearDown(bloc.close);
    final List<DepositSubmissionState> states = <DepositSubmissionState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);

    bloc.add(const DepositSubmissionRequested(deposit));
    await pumpEventQueue();
    bloc.add(const DepositSubmissionRequested(deposit));
    await pumpEventQueue();
    bloc.add(const DepositSubmissionRequested(deposit));
    await pumpEventQueue();
    bloc.add(const DepositSubmissionRequested(deposit));
    await pumpEventQueue();
    bloc.add(const DepositSubmissionRetryRequested());
    await pumpEventQueue();

    expect(states.whereType<DepositSubmissionRecorded>(), hasLength(1));
    expect(states.whereType<DepositSubmissionReplayed>(), hasLength(2));
    expect(states.whereType<DepositSubmissionConflict>(), hasLength(1));
    expect(states.whereType<DepositSubmissionRetryableFailure>(), hasLength(1));
    expect(transport.submissions, hasLength(5));
    expect(identical(transport.submissions[3], transport.submissions[4]), isTrue);
    for (final DepositSubmissionState state in states) {
      expect(state.toString(), isNot(contains('customer-private-001')));
      expect(state.toString(), isNot(contains('provider-private-001')));
    }
  });

  test('queues overlapping distinct submissions instead of dropping either', () async {
    final _DelayedTransport transport = _DelayedTransport();
    final DepositSubmissionBloc bloc = DepositSubmissionBloc(transport: transport);
    addTearDown(bloc.close);
    final ProviderDeposit first = depositWithReference('private-first');
    final ProviderDeposit second = depositWithReference('private-second');

    bloc.add(DepositSubmissionRequested(first));
    bloc.add(DepositSubmissionRequested(second));
    await pumpEventQueue();
    expect(transport.submissions, <ProviderDeposit>[first]);

    transport.recorded(0);
    await pumpEventQueue();
    expect(transport.submissions, <ProviderDeposit>[first, second]);

    transport.recorded(1);
    await pumpEventQueue();
  });

  test('retries every retained unavailable submission in FIFO order after later success', () async {
    final _DelayedTransport transport = _DelayedTransport();
    final DepositSubmissionBloc bloc = DepositSubmissionBloc(transport: transport);
    addTearDown(bloc.close);
    final ProviderDeposit first = depositWithReference('private-first');
    final ProviderDeposit second = depositWithReference('private-second');
    final ProviderDeposit laterSuccess = depositWithReference('private-success');

    bloc.add(DepositSubmissionRequested(first));
    bloc.add(DepositSubmissionRequested(second));
    bloc.add(DepositSubmissionRequested(laterSuccess));
    await pumpEventQueue();
    transport.unavailable(0);
    await pumpEventQueue();
    transport.unavailable(1);
    await pumpEventQueue();
    transport.recorded(2);
    await pumpEventQueue();

    bloc.add(const DepositSubmissionRetryRequested());
    await pumpEventQueue();
    expect(transport.submissions, <ProviderDeposit>[
      first,
      second,
      laterSuccess,
      first,
    ]);
    transport.recorded(3);
    await pumpEventQueue();
    expect(transport.submissions.last, second);
    transport.recorded(4);
    await pumpEventQueue();
  });
}
