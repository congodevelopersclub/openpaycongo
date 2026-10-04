import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../sms_gateway/domain/sms_gateway.dart';
import '../data/encrypted_sms_release_store.dart';
import '../domain/signed_sms_deposit_parser.dart';
import 'deposit_submission_bloc.dart';

enum SmsDepositSyncStatus { idle, syncing, reviewRequired, queued, storageUnavailable }

/// Runs only inside the unlocked, SMS-authorized, activated pairing view.
/// Captured data never enters its state. A failed parse retains native evidence.
final class SmsDepositCoordinator extends Cubit<SmsDepositSyncStatus> {
  SmsDepositCoordinator({required this.gateway, required this.releases,
    required this.submissions, DateTime Function()? now})
      : now = now ?? DateTime.now, super(SmsDepositSyncStatus.idle);
  final SmsGatewayPort gateway;
  final SmsDepositReleaseStore releases;
  final DepositSubmissionBloc submissions;
  final DateTime Function() now;
  bool _running = false;
  bool _stopped = false;

  Future<bool> installRelease(String bundle) async {
    if (_running || _stopped) return false;
    _running = true;
    bool accepted = false;
    try { accepted = await releases.install(bundle, now()); }
    on Object { if (!isClosed) emit(SmsDepositSyncStatus.storageUnavailable); }
    finally { _running = false; }
    if (accepted) await sync();
    return accepted;
  }

  Future<void> sync() async {
    if (_running || _stopped) return;
    _running = true;
    emit(SmsDepositSyncStatus.syncing);
    try {
      final NativeCaptureHealth health = await gateway.captureHealth();
      if (_stopped) return;
      if (health.recoveryRequired || health.fault == CaptureFault.corruption || health.fault == CaptureFault.keyInvalidated) {
        emit(SmsDepositSyncStatus.storageUnavailable);
        return;
      }
      // Native trusted rules remain authoritative even with a valid release.
      final Set<String> trusted = (await gateway.listTrustedSenders()).toSet();
      final List<SignedSmsDepositRelease> patterns = await releases.current(now());
      final Map<String, SignedSmsDepositRelease> bySender = <String, SignedSmsDepositRelease>{
        for (final SignedSmsDepositRelease release in patterns) release.sender: release,
      };
      final List<NativeSmsRecord> records = await gateway.drainInbox();
      if (_stopped) return;
      // Retry retained failures before staging new captured records.
      submissions.add(const DepositSubmissionRetryRequested());
      int queued = 0;
      int review = 0;
      for (final NativeSmsRecord record in records) {
        if (_stopped) return;
        final SignedSmsDepositRelease? release = bySender[record.sender];
        final ProviderDeposit? deposit = release == null || !trusted.contains(record.sender) ? null
            : const SignedSmsDepositParser().parse(record, release, now());
        if (deposit == null) { review++; continue; }
        final bool staged = await submissions.stageCaptured(deposit, afterStage: () async {
          if (_stopped) throw StateError('sms_sync_stopped');
          await gateway.commitInboxDecision(record.id, NativeCaptureDecision.processed);
        });
        if (_stopped) return;
        if (!staged) { emit(SmsDepositSyncStatus.storageUnavailable); return; }
        queued++;
      }
      if (_stopped) return;
      emit(review > 0 ? SmsDepositSyncStatus.reviewRequired : queued > 0 ? SmsDepositSyncStatus.queued : SmsDepositSyncStatus.idle);
    } on Object {
      if (!_stopped) emit(SmsDepositSyncStatus.storageUnavailable);
    } finally { _running = false; }
  }

  @override
  Future<void> close() async {
    _stopped = true;
    await super.close();
  }
}
