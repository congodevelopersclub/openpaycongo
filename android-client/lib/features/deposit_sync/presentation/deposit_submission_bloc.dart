import 'dart:async';
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

/// Durable encrypted implementation belongs to the paired-installation owner.
/// This boundary stores ingress only before an authenticated attempt; it never
/// exposes it through BLoC state, errors, telemetry, or serialization.
abstract interface class DepositSubmissionJournal {
  Future<void> stage(ProviderDeposit deposit);

  Future<List<ProviderDeposit>> loadPending();

  Future<void> remove(ProviderDeposit deposit);

  /// Atomically moves a server-rejected request out of automatic replay,
  /// retaining it for explicit recovery without exposing ingress data. A
  /// durable implementation must fail closed rather than later returning an
  /// unresolved conflict from [loadPending].
  Future<void> markConflict(ProviderDeposit deposit);
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

/// Reloads pending intent after process restart or explicit reconnect.
final class DepositSubmissionStarted extends DepositSubmissionEvent {
  const DepositSubmissionStarted();
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

final class _DepositSubmissionStartAwaited extends DepositSubmissionEvent {
  const _DepositSubmissionStartAwaited(this.completer);

  final Completer<void> completer;
}

/// Staging or durable terminal-state update failed. No request is retried by
/// this state; an owner must reconcile encrypted journal state first.
final class DepositSubmissionPersistenceFailure extends DepositSubmissionState {
  const DepositSubmissionPersistenceFailure();
}

final class DepositSubmissionBloc
    extends Bloc<DepositSubmissionEvent, DepositSubmissionState> {
  DepositSubmissionBloc({required this.transport, required this.journal})
    : super(const DepositSubmissionIdle()) {
    on<DepositSubmissionRequested>(_submit);
    on<DepositSubmissionStarted>(_start);
    on<_DepositSubmissionStartAwaited>(_startAwaited);
    on<DepositSubmissionRetryRequested>(_retry);
  }

  final AuthenticatedDepositTransport transport;
  final DepositSubmissionJournal journal;
  final Queue<ProviderDeposit> _pending = Queue<ProviderDeposit>();
  final List<ProviderDeposit> _retryable = <ProviderDeposit>[];
  bool _draining = false;

  /// Runtime-only startup barrier. The public event remains available for an
  /// explicit reconnect, while composition awaits durable replay before
  /// exposing this BLoC to callers.
  Future<void> start() {
    final Completer<void> completer = Completer<void>();
    add(_DepositSubmissionStartAwaited(completer));
    return completer.future;
  }

  Future<void> _submit(
    DepositSubmissionRequested event,
    Emitter<DepositSubmissionState> emit,
  ) async {
    try {
      await journal.stage(event.deposit);
    } on Object {
      emit(const DepositSubmissionPersistenceFailure());
      return;
    }
    await _enqueue(<ProviderDeposit>[event.deposit], emit);
  }

  Future<void> _start(
    DepositSubmissionStarted event,
    Emitter<DepositSubmissionState> emit,
  ) async {
    try {
      await _enqueue(await journal.loadPending(), emit);
    } on Object {
      emit(const DepositSubmissionPersistenceFailure());
    }
  }

  Future<void> _startAwaited(
    _DepositSubmissionStartAwaited event,
    Emitter<DepositSubmissionState> emit,
  ) async {
    try {
      await _start(const DepositSubmissionStarted(), emit);
    } on Object {
      emit(const DepositSubmissionPersistenceFailure());
    } finally {
      event.completer.complete();
    }
  }

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
          if (result.outcome == DepositSubmissionOutcome.conflict) {
            try {
              await journal.markConflict(deposit);
            } on Object {
              emit(const DepositSubmissionPersistenceFailure());
              continue;
            }
            emit(const DepositSubmissionConflict());
            continue;
          }
          try {
            await journal.remove(deposit);
          } on Object {
            emit(const DepositSubmissionPersistenceFailure());
            continue;
          }
          switch (result.outcome) {
            case DepositSubmissionOutcome.recorded:
              emit(const DepositSubmissionRecorded());
            case DepositSubmissionOutcome.replayed:
              emit(const DepositSubmissionReplayed());
            case DepositSubmissionOutcome.conflict:
              break;
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
