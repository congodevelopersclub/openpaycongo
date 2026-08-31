import 'dart:collection';

import 'package:flutter_bloc/flutter_bloc.dart';

/// Sensitive ingress data. It exists only at caller-to-authenticated-transport
/// boundary; no BLoC state, error, telemetry, or serialization owns it.
final class ProviderDeposit {
  const ProviderDeposit({
    required this.customerLookupIdentifier,
    required this.providerReference,
    required this.amountMinor,
    required this.currency,
    required this.providerOccurredAt,
    this.senderIdentifier,
    this.receiverIdentifier,
    this.customerName,
    this.customerAddress,
    this.customerPhone,
    this.customerEmail,
  });

  final String customerLookupIdentifier;
  final String providerReference;
  final int amountMinor;
  final String currency;
  final String providerOccurredAt;
  final String? senderIdentifier;
  final String? receiverIdentifier;
  final String? customerName;
  final String? customerAddress;
  final String? customerPhone;
  final String? customerEmail;
}

enum DepositSubmissionOutcome { recorded, replayed, conflict }

final class DepositSubmissionResult {
  const DepositSubmissionResult._(this.outcome);

  const DepositSubmissionResult.recorded()
    : this._(DepositSubmissionOutcome.recorded);
  const DepositSubmissionResult.replayed()
    : this._(DepositSubmissionOutcome.replayed);
  const DepositSubmissionResult.conflict()
    : this._(DepositSubmissionOutcome.conflict);

  final DepositSubmissionOutcome outcome;
}

/// Paired-installation owner injects this port after auth provisioning.
/// This feature never issues, loads, logs, or persists credentials.
abstract interface class AuthenticatedDepositTransport {
  Future<DepositSubmissionResult> submit(ProviderDeposit deposit);
}

/// Expected reconnect-safe transport failure. No server acknowledgement known,
/// so retry submits same immutable request to server idempotency logic.
final class DepositTransportUnavailable implements Exception {
  const DepositTransportUnavailable();
}

sealed class DepositSubmissionEvent {
  const DepositSubmissionEvent();
}

final class DepositSubmissionRequested extends DepositSubmissionEvent {
  const DepositSubmissionRequested(this.deposit);

  final ProviderDeposit deposit;
}

final class DepositSubmissionRetryRequested extends DepositSubmissionEvent {
  const DepositSubmissionRetryRequested();
}

sealed class DepositSubmissionState {
  const DepositSubmissionState();
}

final class DepositSubmissionIdle extends DepositSubmissionState {
  const DepositSubmissionIdle();
}

final class DepositSubmissionSubmitting extends DepositSubmissionState {
  const DepositSubmissionSubmitting();
}

final class DepositSubmissionRecorded extends DepositSubmissionState {
  const DepositSubmissionRecorded();
}

final class DepositSubmissionReplayed extends DepositSubmissionState {
  const DepositSubmissionReplayed();
}

final class DepositSubmissionConflict extends DepositSubmissionState {
  const DepositSubmissionConflict();
}

final class DepositSubmissionRetryableFailure extends DepositSubmissionState {
  const DepositSubmissionRetryableFailure();
}

final class DepositSubmissionBloc
    extends Bloc<DepositSubmissionEvent, DepositSubmissionState> {
  DepositSubmissionBloc({required this.transport})
    : super(const DepositSubmissionIdle()) {
    on<DepositSubmissionRequested>(_submit);
    on<DepositSubmissionRetryRequested>(_retry);
  }

  final AuthenticatedDepositTransport transport;
  final Queue<ProviderDeposit> _pending = Queue<ProviderDeposit>();
  final List<ProviderDeposit> _retryable = <ProviderDeposit>[];
  bool _draining = false;

  Future<void> _submit(
    DepositSubmissionRequested event,
    Emitter<DepositSubmissionState> emit,
  ) => _enqueue(<ProviderDeposit>[event.deposit], emit);

  Future<void> _retry(
    DepositSubmissionRetryRequested event,
    Emitter<DepositSubmissionState> emit,
  ) async => _enqueue(_takeRetryable(), emit);

  List<ProviderDeposit> _takeRetryable() {
    final List<ProviderDeposit> retryable = List<ProviderDeposit>.of(
      _retryable,
    );
    _retryable.clear();
    return retryable;
  }

  Future<void> _enqueue(
    Iterable<ProviderDeposit> deposits,
    Emitter<DepositSubmissionState> emit,
  ) async {
    _pending.addAll(deposits);
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final ProviderDeposit deposit = _pending.removeFirst();
        emit(const DepositSubmissionSubmitting());
        try {
          final DepositSubmissionResult result = await transport.submit(deposit);
          switch (result.outcome) {
            case DepositSubmissionOutcome.recorded:
              emit(const DepositSubmissionRecorded());
            case DepositSubmissionOutcome.replayed:
              emit(const DepositSubmissionReplayed());
            case DepositSubmissionOutcome.conflict:
              emit(const DepositSubmissionConflict());
          }
        } on DepositTransportUnavailable {
          _retryable.add(deposit);
          emit(const DepositSubmissionRetryableFailure());
        }
      }
    } finally {
      _draining = false;
    }
  }
}
