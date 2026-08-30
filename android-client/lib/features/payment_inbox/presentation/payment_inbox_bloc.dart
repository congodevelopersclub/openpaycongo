import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../sms_gateway/domain/sms_gateway.dart';
import '../domain/payment_ingestion.dart';

enum PaymentInboxAuthority { loading, authoritative, unknown }

enum PaymentInboxFeedback {
  none,
  invalidSender,
  invalidTemplate,
  ruleSaved,
  inboxUnavailable,
  legacyRecoveryRequired,
  decisionReloaded,
  decisionReloadFailed,
  decisionCommittedHealthUnknown,
  probeReloaded,
  probeReloadFailed,
  ruleAddReloaded,
  ruleAddReloadFailed,
  ruleRevokeReloaded,
  ruleRevokeReloadFailed,
  ruleClearReloaded,
  ruleClearReloadFailed,
}

final class PaymentInboxState {
  const PaymentInboxState({
    this.ready = false,
    this.authority = PaymentInboxAuthority.loading,
    this.trustedSenders = const <SenderIdentity>[],
    this.records = const <NativeSmsRecord>[],
    this.health,
    this.busyRecordIds = const <String>{},
    this.feedback = PaymentInboxFeedback.none,
  });

  final bool ready;
  final PaymentInboxAuthority authority;
  final List<SenderIdentity> trustedSenders;
  final List<NativeSmsRecord> records;
  final NativeCaptureHealth? health;
  final Set<String> busyRecordIds;
  final PaymentInboxFeedback feedback;

  PaymentInboxState copyWith({
    bool? ready,
    PaymentInboxAuthority? authority,
    List<SenderIdentity>? trustedSenders,
    List<NativeSmsRecord>? records,
    NativeCaptureHealth? health,
    bool clearHealth = false,
    Set<String>? busyRecordIds,
    PaymentInboxFeedback? feedback,
  }) => PaymentInboxState(
    ready: ready ?? this.ready,
    authority: authority ?? this.authority,
    trustedSenders: trustedSenders ?? this.trustedSenders,
    records: records ?? this.records,
    health: clearHealth ? null : health ?? this.health,
    busyRecordIds: busyRecordIds ?? this.busyRecordIds,
    feedback: feedback ?? this.feedback,
  );
}

sealed class PaymentInboxEvent {
  const PaymentInboxEvent();
}

final class PaymentInboxStarted extends PaymentInboxEvent {
  const PaymentInboxStarted();
}

final class PaymentInboxReloadRequested extends PaymentInboxEvent {
  const PaymentInboxReloadRequested();
}

final class PaymentInboxStorageProbeRequested extends PaymentInboxEvent {
  const PaymentInboxStorageProbeRequested();
}

final class PaymentInboxTrustedSenderSaveRequested extends PaymentInboxEvent {
  const PaymentInboxTrustedSenderSaveRequested({
    required this.sender,
    required this.template,
  });

  final String sender;
  final String template;
}

final class PaymentInboxTrustedSenderRevoked extends PaymentInboxEvent {
  const PaymentInboxTrustedSenderRevoked(this.sender);

  final SenderIdentity sender;
}

final class PaymentInboxTrustedSendersCleared extends PaymentInboxEvent {
  const PaymentInboxTrustedSendersCleared();
}

final class PaymentInboxDecisionRequested extends PaymentInboxEvent {
  const PaymentInboxDecisionRequested({
    required this.recordId,
    required this.decision,
  });

  final String recordId;
  final NativeCaptureDecision decision;
}

/// Owns native inbox mutation and reconciliation state. It never logs or
/// serializes captured SMS evidence; widgets render the in-memory result.
final class PaymentInboxBloc
    extends Bloc<PaymentInboxEvent, PaymentInboxState> {
  PaymentInboxBloc({required this.gateway}) : super(const PaymentInboxState()) {
    on<PaymentInboxEvent>(_enqueue);
  }

  final SmsGatewayPort gateway;
  Future<void> _queue = Future<void>.value();

  Future<void> _enqueue(
    PaymentInboxEvent event,
    Emitter<PaymentInboxState> emit,
  ) {
    final Future<void> operation = _queue.then<void>(
      (_) => _handle(event, emit),
    );
    _queue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _handle(
    PaymentInboxEvent event,
    Emitter<PaymentInboxState> emit,
  ) => switch (event) {
    PaymentInboxStarted() => _start(event, emit),
    PaymentInboxReloadRequested() => _reloadRequested(event, emit),
    PaymentInboxStorageProbeRequested() => _probeStorage(event, emit),
    PaymentInboxTrustedSenderSaveRequested() => _saveRule(event, emit),
    PaymentInboxTrustedSenderRevoked() => _revokeRule(event, emit),
    PaymentInboxTrustedSendersCleared() => _clearRules(event, emit),
    PaymentInboxDecisionRequested() => _commitDecision(event, emit),
  };

  Future<void> _start(
    PaymentInboxStarted event,
    Emitter<PaymentInboxState> emit,
  ) => _reload(emit, feedback: PaymentInboxFeedback.none);

  Future<void> _reloadRequested(
    PaymentInboxReloadRequested event,
    Emitter<PaymentInboxState> emit,
  ) => _reload(emit, feedback: PaymentInboxFeedback.none);

  Future<bool> _reload(
    Emitter<PaymentInboxState> emit, {
    required PaymentInboxFeedback feedback,
  }) async {
    emit(
      state.copyWith(
        authority: PaymentInboxAuthority.loading,
        feedback: feedback,
      ),
    );
    try {
      final List<String> storedSenders = await gateway.listTrustedSenders();
      final List<SenderIdentity> trustedSenders = _decodeTrustedSenders(
        storedSenders,
      );
      final NativeCaptureHealth health = await gateway.captureHealth();
      final bool blocksRead =
          health.fault == CaptureFault.corruption ||
          health.fault == CaptureFault.keyInvalidated ||
          health.recoveryRequired;
      final List<NativeSmsRecord> records = blocksRead
          ? const <NativeSmsRecord>[]
          : await gateway.drainInbox();
      emit(
        state.copyWith(
          ready: true,
          authority: PaymentInboxAuthority.authoritative,
          trustedSenders: trustedSenders,
          records: records,
          health: health,
          feedback: feedback,
        ),
      );
      return true;
    } on Object catch (error) {
      emit(
        PaymentInboxState(
          ready: true,
          authority: PaymentInboxAuthority.unknown,
          feedback: _failureFeedback(error),
        ),
      );
      return false;
    }
  }

  Future<void> _probeStorage(
    PaymentInboxStorageProbeRequested event,
    Emitter<PaymentInboxState> emit,
  ) async {
    try {
      await gateway.probeStorage();
      await _reload(emit, feedback: PaymentInboxFeedback.none);
    } on Object {
      final bool reloaded = await _reload(
        emit,
        feedback: PaymentInboxFeedback.none,
      );
      if (reloaded) {
        emit(state.copyWith(feedback: PaymentInboxFeedback.probeReloaded));
      } else {
        emit(state.copyWith(feedback: PaymentInboxFeedback.probeReloadFailed));
      }
    }
  }

  Future<void> _saveRule(
    PaymentInboxTrustedSenderSaveRequested event,
    Emitter<PaymentInboxState> emit,
  ) async {
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(event.sender);
    if (sender == null) {
      emit(state.copyWith(feedback: PaymentInboxFeedback.invalidSender));
      return;
    }
    if (!PaymentTemplate(event.template.trim()).valid) {
      emit(state.copyWith(feedback: PaymentInboxFeedback.invalidTemplate));
      return;
    }
    try {
      final List<String> values = await gateway.addTrustedSender(sender.value);
      emit(
        state.copyWith(
          authority: PaymentInboxAuthority.authoritative,
          trustedSenders: _decodeTrustedSenders(values),
          feedback: PaymentInboxFeedback.ruleSaved,
        ),
      );
    } on Object {
      final bool reloaded = await _reload(
        emit,
        feedback: PaymentInboxFeedback.none,
      );
      emit(
        state.copyWith(
          feedback: reloaded
              ? PaymentInboxFeedback.ruleAddReloaded
              : PaymentInboxFeedback.ruleAddReloadFailed,
        ),
      );
    }
  }

  Future<void> _revokeRule(
    PaymentInboxTrustedSenderRevoked event,
    Emitter<PaymentInboxState> emit,
  ) async {
    try {
      final List<String> values = await gateway.revokeTrustedSender(
        event.sender.value,
      );
      emit(
        state.copyWith(
          authority: PaymentInboxAuthority.authoritative,
          trustedSenders: _decodeTrustedSenders(values),
          feedback: PaymentInboxFeedback.none,
        ),
      );
    } on Object {
      final bool reloaded = await _reload(
        emit,
        feedback: PaymentInboxFeedback.none,
      );
      emit(
        state.copyWith(
          feedback: reloaded
              ? PaymentInboxFeedback.ruleRevokeReloaded
              : PaymentInboxFeedback.ruleRevokeReloadFailed,
        ),
      );
    }
  }

  Future<void> _clearRules(
    PaymentInboxTrustedSendersCleared event,
    Emitter<PaymentInboxState> emit,
  ) async {
    try {
      final List<String> values = await gateway.clearTrustedSenders();
      emit(
        state.copyWith(
          authority: PaymentInboxAuthority.authoritative,
          trustedSenders: _decodeTrustedSenders(values),
          feedback: PaymentInboxFeedback.none,
        ),
      );
    } on Object {
      final bool reloaded = await _reload(
        emit,
        feedback: PaymentInboxFeedback.none,
      );
      emit(
        state.copyWith(
          feedback: reloaded
              ? PaymentInboxFeedback.ruleClearReloaded
              : PaymentInboxFeedback.ruleClearReloadFailed,
        ),
      );
    }
  }

  Future<void> _commitDecision(
    PaymentInboxDecisionRequested event,
    Emitter<PaymentInboxState> emit,
  ) async {
    if (state.busyRecordIds.contains(event.recordId)) return;
    final Set<String> busy = <String>{...state.busyRecordIds, event.recordId};
    emit(
      state.copyWith(busyRecordIds: busy, feedback: PaymentInboxFeedback.none),
    );
    try {
      await gateway.commitInboxDecision(event.recordId, event.decision);
      final List<NativeSmsRecord> records = state.records
          .where((NativeSmsRecord record) => record.id != event.recordId)
          .toList(growable: false);
      try {
        final NativeCaptureHealth health = await gateway.captureHealth();
        emit(state.copyWith(records: records, health: health));
      } on Object {
        final bool reloaded = await _reload(
          emit,
          feedback: PaymentInboxFeedback.none,
        );
        emit(
          state.copyWith(
            feedback: reloaded
                ? PaymentInboxFeedback.decisionCommittedHealthUnknown
                : PaymentInboxFeedback.decisionReloadFailed,
          ),
        );
      }
    } on Object {
      final bool reloaded = await _reload(
        emit,
        feedback: PaymentInboxFeedback.none,
      );
      emit(
        state.copyWith(
          feedback: reloaded
              ? PaymentInboxFeedback.decisionReloaded
              : PaymentInboxFeedback.decisionReloadFailed,
        ),
      );
    } finally {
      emit(
        state.copyWith(
          busyRecordIds: <String>{...state.busyRecordIds}
            ..remove(event.recordId),
        ),
      );
    }
  }

  List<SenderIdentity> _decodeTrustedSenders(List<String> values) {
    final List<SenderIdentity> decoded = values
        .map(SenderIdentity.fromOsMetadata)
        .whereType<SenderIdentity>()
        .toList(growable: false);
    if (decoded.length != values.length) {
      throw const FormatException('invalid_native_trusted_sender');
    }
    return decoded;
  }

  PaymentInboxFeedback _failureFeedback(Object error) =>
      error is PlatformException && error.code == 'legacy_migration_required'
      ? PaymentInboxFeedback.legacyRecoveryRequired
      : PaymentInboxFeedback.inboxUnavailable;
}
