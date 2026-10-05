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
    this.parserEvidence,
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
  final DepositParserEvidence? parserEvidence;
}

/// Signed parser provenance remains encrypted with the immutable request.
/// A trusted SMS sender is evidence of a report, not proof of settlement.
final class DepositParserEvidence {
  const DepositParserEvidence({
    required this.provider,
    required this.smsSender,
    required this.parserVersion,
    required this.smsReceivedAt,
    required this.evidenceDigest,
    required this.parserReleaseId,
  });

  final String provider;
  final String smsSender;
  final int parserVersion;
  final String smsReceivedAt;
  final String evidenceDigest;
  final String parserReleaseId;

  Map<String, Object> toMap() => <String, Object>{
    'kind': 'signed_release',
    'provider': provider,
    'sms_sender': smsSender,
    'parser_version': parserVersion,
    'sms_received_at': smsReceivedAt,
    'evidence_digest': evidenceDigest,
    'parser_release_id': parserReleaseId,
  };

  static DepositParserEvidence fromMap(Object? value) {
    if (value is! Map<String, dynamic> || value.length != 7 ||
        value['kind'] != 'signed_release' || value['provider'] is! String ||
        value['sms_sender'] is! String || value['parser_version'] is! int ||
        (value['parser_version'] as int) < 1 || value['sms_received_at'] is! String ||
        value['evidence_digest'] is! String || value['parser_release_id'] is! String) {
      throw const FormatException('invalid_parser_evidence');
    }
    return DepositParserEvidence(
      provider: value['provider'] as String,
      smsSender: value['sms_sender'] as String,
      parserVersion: value['parser_version'] as int,
      smsReceivedAt: value['sms_received_at'] as String,
      evidenceDigest: value['evidence_digest'] as String,
      parserReleaseId: value['parser_release_id'] as String,
    );
  }
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

/// Keeps the first signed SMS request immutable across duplicate capture,
/// including after server acknowledgement. Evidence times never become a new
/// financial intent merely because the operator repeats its notification.
abstract interface class ImmutableSmsDepositJournal {
  Future<StagedSmsDeposit> stageSms(ProviderDeposit deposit);
}

/// Valid encrypted storage contains conflicting transfer semantics. Retain the
/// native SMS for review without treating unrelated pending evidence as corrupt.
final class SmsDepositSemanticConflict implements Exception {
  const SmsDepositSemanticConflict();
}

final class StagedSmsDeposit {
  const StagedSmsDeposit(this.deposit, {this.acknowledged = false});
  final ProviderDeposit deposit;
  final bool acknowledged;
}

final class _DepositSubmissionStageAwaited extends DepositSubmissionEvent {
  const _DepositSubmissionStageAwaited(this.deposit, this.afterStage, this.completion);
  final ProviderDeposit deposit;
  final Future<void> Function() afterStage;
  final Completer<bool> completion;
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
    on<DepositSubmissionEvent>((event, emit) {
      final Future<void> operation = _events.then<void>((_) => switch (event) {
        DepositSubmissionRequested() => _submit(event, emit),
        DepositSubmissionStarted() => _start(event, emit),
        _DepositSubmissionStartAwaited() => _startAwaited(event, emit),
        DepositSubmissionRetryRequested() => _retry(event, emit),
        _DepositSubmissionStageAwaited() => _stageAwaited(event, emit),
      });
      _events = operation.catchError((Object _) {});
      return operation;
    });
  }

  final AuthenticatedDepositTransport transport;
  final DepositSubmissionJournal journal;
  final Queue<ProviderDeposit> _pending = Queue<ProviderDeposit>();
  final List<ProviderDeposit> _retryable = <ProviderDeposit>[];
  bool _draining = false;
  Future<void> _events = Future<void>.value();

  /// Runtime-only startup barrier. The public event remains available for an
  /// explicit reconnect, while composition awaits durable replay before
  /// exposing this BLoC to callers.
  Future<void> start() {
    final Completer<void> completer = Completer<void>();
    add(_DepositSubmissionStartAwaited(completer));
    return completer.future;
  }

  /// Transfers native evidence only after encrypted intent is durable.
  /// A process death between the two writes leaves the raw SMS available for
  /// the same idempotent request, while startup replays the staged request.
  Future<bool> stageCaptured(
    ProviderDeposit deposit, {
    required Future<void> Function() afterStage,
  }) {
    final Completer<bool> completion = Completer<bool>();
    add(_DepositSubmissionStageAwaited(deposit, afterStage, completion));
    return completion.future;
  }

  Future<void> _stageAwaited(
    _DepositSubmissionStageAwaited event,
    Emitter<DepositSubmissionState> emit,
  ) async {
    StagedSmsDeposit staged = StagedSmsDeposit(event.deposit);
    try {
      if (journal case final ImmutableSmsDepositJournal immutable when event.deposit.parserEvidence != null) {
        staged = await immutable.stageSms(event.deposit);
      } else {
        await journal.stage(event.deposit);
      }
      await event.afterStage();
    } on SmsDepositSemanticConflict {
      emit(const DepositSubmissionConflict());
      event.completion.completeError(const SmsDepositSemanticConflict());
      return;
    } on Object {
      emit(const DepositSubmissionPersistenceFailure());
      event.completion.complete(false);
      return;
    }
    event.completion.complete(true);
    if (journal is ImmutableSmsDepositJournal && staged.deposit.parserEvidence != null) {
      // A duplicate capture returns the first immutable request. Replace its
      // retained retry before enqueueing it again, so one acknowledgement
      // cannot be followed by a second journal update for the same intent.
      _retryable.removeWhere((ProviderDeposit retry) =>
          retry.parserEvidence != null &&
          retry.providerReference == staged.deposit.providerReference &&
          retry.parserEvidence!.provider == staged.deposit.parserEvidence!.provider &&
          retry.parserEvidence!.smsSender == staged.deposit.parserEvidence!.smsSender);
    }
    if (staged.acknowledged) {
      emit(const DepositSubmissionReplayed());
      return;
    }
    await _enqueue(<ProviderDeposit>[staged.deposit], emit);
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
