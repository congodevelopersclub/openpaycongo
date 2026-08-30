import 'package:flutter/material.dart';

import '../../pairing/presentation/pairing_session_bloc.dart';
import '../../pairing/presentation/pairing_session_status_card.dart';
import '../../pairing/presentation/pairing_enrollment_bloc.dart';
import '../../pairing/presentation/pairing_enrollment_status_card.dart';
import '../../sync_diagnosis/presentation/sync_cursor_bloc.dart';
import '../../sync_diagnosis/presentation/sync_cursor_card.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../sms_gateway/domain/sms_gateway.dart';
import 'payment_inbox_bloc.dart';
import '../../payment_outbox/presentation/payment_lifecycle_bloc.dart';
import '../../payment_outbox/presentation/payment_lifecycle_status_card.dart';
import '../../payment_outbox/presentation/payment_request_lifecycle_bloc.dart';
import '../../payment_outbox/presentation/payment_request_lifecycle_card.dart';
import '../domain/payment_ingestion.dart';

final class PaymentInboxScreen extends StatefulWidget {
  const PaymentInboxScreen({
    super.key,
    this.smsPermissionState = SmsPermissionState.ready,
    this.gemmaCapability = const GemmaRuntimePending(),
    this.pairingEnrollment,
    this.pairingSession,
    this.paymentLifecycle,
    this.paymentRequestLifecycle,
    this.syncCursor,
    this.inboxBloc,
    required this.gateway,
  });
  final SmsPermissionState smsPermissionState;
  final GemmaCapabilityEvidence gemmaCapability;
  final PairingEnrollmentBloc? pairingEnrollment;
  final PairingSessionBloc? pairingSession;
  final PaymentLifecycleBloc? paymentLifecycle;
  final PaymentRequestLifecycleBloc? paymentRequestLifecycle;
  final SyncCursorBloc? syncCursor;
  final PaymentInboxBloc? inboxBloc;
  final SmsGatewayPort gateway;
  @override
  State<PaymentInboxScreen> createState() => _PaymentInboxScreenState();
}

final class _PaymentInboxScreenState extends State<PaymentInboxScreen> {
  final TextEditingController _sender = TextEditingController();
  final TextEditingController _template = TextEditingController(
    text: '{amount} {currency} {reference}',
  );
  bool _showSetup = false;
  late final PaymentInboxBloc _inboxBloc =
      widget.inboxBloc ?? PaymentInboxBloc(gateway: widget.gateway);
  late final bool _ownsInboxBloc = widget.inboxBloc == null;

  @override
  void initState() {
    super.initState();
    _inboxBloc.add(const PaymentInboxStarted());
  }

  @override
  void dispose() {
    _sender.dispose();
    _template.dispose();
    if (_ownsInboxBloc) _inboxBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PaymentInboxBloc>.value(
      value: _inboxBloc,
      child: BlocConsumer<PaymentInboxBloc, PaymentInboxState>(
        listener: (BuildContext context, PaymentInboxState state) {
          if (state.feedback == PaymentInboxFeedback.ruleSaved && _showSetup) {
            setState(() => _showSetup = false);
          }
        },
        builder: (BuildContext context, PaymentInboxState inbox) {
          final ColorScheme colors = Theme.of(context).colorScheme;
          final NativeCaptureHealth? nativeHealth = inbox.health;
          final String? nativeError = _feedbackMessage(inbox.feedback);
          return Scaffold(
            backgroundColor: colors.surface,
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => setState(() => _showSetup = !_showSetup),
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Review rules'),
            ),
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 112),
                children: <Widget>[
                  Text(
                    'Payment Inbox',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Evidence first. Nothing below is confirmed payment.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _CaptureStatusCard(state: widget.smsPermissionState),
                  if (widget.pairingEnrollment
                      case final PairingEnrollmentBloc enrollment) ...<Widget>[
                    const SizedBox(height: 12),
                    BlocProvider<PairingEnrollmentBloc>.value(
                      value: enrollment,
                      child: const PairingEnrollmentStatusCard(),
                    ),
                  ],
                  if (widget.pairingSession
                      case final PairingSessionBloc pairing) ...<Widget>[
                    const SizedBox(height: 12),
                    BlocProvider<PairingSessionBloc>.value(
                      value: pairing,
                      child: const PairingSessionStatusCard(),
                    ),
                  ],
                  if (widget.syncCursor
                      case final SyncCursorBloc sync) ...<Widget>[
                    const SizedBox(height: 12),
                    SyncCursorCard(bloc: sync),
                  ],
                  if (widget.paymentLifecycle
                      case final PaymentLifecycleBloc lifecycle) ...<Widget>[
                    const SizedBox(height: 12),
                    BlocProvider<PaymentLifecycleBloc>.value(
                      value: lifecycle,
                      child: const PaymentLifecycleStatusCard(),
                    ),
                  ],
                  if (widget.paymentRequestLifecycle
                      case final PaymentRequestLifecycleBloc
                          lifecycle) ...<Widget>[
                    const SizedBox(height: 12),
                    BlocProvider<PaymentRequestLifecycleBloc>.value(
                      value: lifecycle,
                      child: const PaymentRequestLifecycleCard(),
                    ),
                  ],
                  if (nativeHealth?.fault != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _CaptureFaultCard(
                      fault: nativeHealth!.fault!,
                      onOpenSettings: widget.gateway.openSettings,
                      onProbeStorage: () async => _inboxBloc.add(
                        const PaymentInboxStorageProbeRequested(),
                      ),
                    ),
                  ],
                  if (nativeHealth?.recoveryRequired == true) ...<Widget>[
                    const SizedBox(height: 12),
                    const _RecoveryRequiredCard(),
                  ],
                  if (nativeHealth?.missed != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _CaptureMissCard(signal: nativeHealth!.missed!),
                  ],
                  if (nativeError != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _NativeErrorCard(
                      message: nativeError,
                      onRetry: () async {
                        _inboxBloc.add(const PaymentInboxReloadRequested());
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  _GemmaStatusCard(capability: widget.gemmaCapability),
                  if (inbox.authority ==
                      PaymentInboxAuthority.loading) ...<Widget>[
                    const SizedBox(height: 12),
                    const _TrustedRulesStateCard(
                      message: 'Loading authoritative trusted sender rules…',
                    ),
                  ],
                  if (inbox.authority ==
                      PaymentInboxAuthority.unknown) ...<Widget>[
                    const SizedBox(height: 12),
                    const _TrustedRulesStateCard(
                      message:
                          'Trusted sender state is unknown. Automatic capture cannot be trusted until reload succeeds.',
                    ),
                  ],
                  if (inbox.authority == PaymentInboxAuthority.authoritative &&
                      inbox.trustedSenders.isEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    const _NoTrustedSendersCard(),
                  ],
                  if (inbox.authority == PaymentInboxAuthority.authoritative &&
                      inbox.trustedSenders.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    _TrustedRuleStatus(
                      senders: inbox.trustedSenders,
                      onRevoke: (SenderIdentity sender) async => _inboxBloc.add(
                        PaymentInboxTrustedSenderRevoked(sender),
                      ),
                      onClear: () async => _inboxBloc.add(
                        const PaymentInboxTrustedSendersCleared(),
                      ),
                    ),
                  ],
                  if (_showSetup) ...<Widget>[
                    const SizedBox(height: 20),
                    _SetupCard(
                      sender: _sender,
                      template: _template,
                      error: _setupFeedbackMessage(inbox.feedback),
                      trustedSenders: inbox.trustedSenders,
                      onSave: () async => _inboxBloc.add(
                        PaymentInboxTrustedSenderSaveRequested(
                          sender: _sender.text,
                          template: _template.text,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (inbox.authority == PaymentInboxAuthority.authoritative &&
                      inbox.records.isNotEmpty) ...<Widget>[
                    Text(
                      'Captured securely',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Choose a durable review decision. The encrypted raw record is removed only after that decision commits.',
                    ),
                    const SizedBox(height: 10),
                    for (final NativeSmsRecord record in inbox.records)
                      _NativeSmsCard(
                        record: record,
                        busy: inbox.busyRecordIds.contains(record.id),
                        onReviewed: () => _inboxBloc.add(
                          PaymentInboxDecisionRequested(
                            recordId: record.id,
                            decision: NativeCaptureDecision.reviewed,
                          ),
                        ),
                        onRejected: () => _confirmReject(record),
                      ),
                    const SizedBox(height: 24),
                  ],
                  if (inbox.authority == PaymentInboxAuthority.authoritative &&
                      inbox.records.isEmpty)
                    const _EmptyReview(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmReject(NativeSmsRecord record) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Reject and remove raw SMS?'),
            content: const Text(
              'Confirming stores a durable rejected decision, then permanently removes the encrypted raw inbox record.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirm reject'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed && mounted) {
      _inboxBloc.add(
        PaymentInboxDecisionRequested(
          recordId: record.id,
          decision: NativeCaptureDecision.rejected,
        ),
      );
    }
  }

  String? _setupFeedbackMessage(
    PaymentInboxFeedback feedback,
  ) => switch (feedback) {
    PaymentInboxFeedback.invalidSender =>
      'Use an exact E.164 number or 3-11 character capital ASCII sender ID.',
    PaymentInboxFeedback.invalidTemplate =>
      'Template uses only {amount}, {currency}, {reference}.',
    _ => null,
  };

  String? _feedbackMessage(PaymentInboxFeedback feedback) => switch (feedback) {
    PaymentInboxFeedback.inboxUnavailable =>
      'Encrypted SMS inbox is unavailable. No message was acknowledged.',
    PaymentInboxFeedback.legacyRecoveryRequired =>
      'Recovery required: legacy encrypted SMS data was detected. Use Android Clear storage or reinstall only after accepting local data loss.',
    PaymentInboxFeedback.decisionReloaded =>
      'Decision outcome is unknown. Authoritative encrypted inbox was reloaded.',
    PaymentInboxFeedback.decisionReloadFailed =>
      'Decision outcome is unknown. Authoritative reload also failed.',
    PaymentInboxFeedback.decisionCommittedHealthUnknown =>
      'Decision was committed. Capture status refresh failed; retry status safely.',
    PaymentInboxFeedback.probeReloaded =>
      'Storage probe outcome is unknown. Authoritative capture health was reloaded.',
    PaymentInboxFeedback.probeReloadFailed =>
      'Storage probe outcome is unknown. Authoritative reload also failed.',
    PaymentInboxFeedback.ruleAddReloaded =>
      'Rule outcome is unknown. Authoritative device rules were reloaded.',
    PaymentInboxFeedback.ruleAddReloadFailed =>
      'Rule outcome is unknown. Authoritative reload also failed.',
    PaymentInboxFeedback.ruleRevokeReloadFailed =>
      'Rule revoke outcome is unknown. Authoritative reload also failed.',
    PaymentInboxFeedback.ruleClearReloadFailed =>
      'Rule outcome is unknown. Authoritative reload also failed.',
    PaymentInboxFeedback.ruleRevokeReloaded =>
      'Rule revoke outcome is unknown. Authoritative rules were reloaded.',
    PaymentInboxFeedback.ruleClearReloaded =>
      'Rule clear outcome is unknown. Authoritative rules were reloaded.',
    _ => null,
  };
}

final class _CaptureStatusCard extends StatelessWidget {
  const _CaptureStatusCard({required this.state});
  final SmsPermissionState state;
  @override
  Widget build(BuildContext context) {
    final bool blocked = state != SmsPermissionState.ready;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(blocked ? Icons.sms_outlined : Icons.sms_rounded),
                const SizedBox(width: 8),
                Text(
                  'Automatic SMS capture',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              blocked
                  ? 'RECEIVE_SMS is required. Return to the permission screen to grant access.'
                  : 'Background capture is active. Only exact trusted OS sender metadata reaches the encrypted local inbox.',
            ),
          ],
        ),
      ),
    );
  }
}

final class _CaptureFaultCard extends StatelessWidget {
  const _CaptureFaultCard({
    required this.fault,
    required this.onOpenSettings,
    required this.onProbeStorage,
  });
  final CaptureFault fault;
  final Future<void> Function()? onOpenSettings;
  final Future<void> Function() onProbeStorage;

  @override
  Widget build(BuildContext context) {
    final bool needsExternalRecovery =
        fault == CaptureFault.corruption ||
        fault == CaptureFault.keyInvalidated;
    final String message = switch (fault) {
      CaptureFault.capacity =>
        'Capture paused: the encrypted inbox is full. Review captured messages to free capacity.',
      CaptureFault.storage =>
        'Capture paused after a storage failure. Existing evidence stays pending; retry review before trusting capture.',
      CaptureFault.corruption =>
        'Encrypted capture data failed authentication and was quarantined. No recovery is claimed.',
      CaptureFault.keyInvalidated =>
        'Android Keystore can no longer open captured data. Records are quarantined; no recovery is claimed.',
    };
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Critical capture fault',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message),
            if (fault == CaptureFault.storage) ...<Widget>[
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: onProbeStorage,
                child: const Text('Retry storage check'),
              ),
            ],
            if (needsExternalRecovery) ...<Widget>[
              const SizedBox(height: 8),
              const Text(
                'Explicit recovery requires Android Clear storage or reinstall, then trusted-sender setup. This can permanently discard unrecoverable ciphertext.',
              ),
              if (onOpenSettings != null)
                TextButton(
                  onPressed: onOpenSettings,
                  child: const Text('Open Android app settings'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _TrustedRulesStateCard extends StatelessWidget {
  const _TrustedRulesStateCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.tertiaryContainer,
    child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
  );
}

final class _RecoveryRequiredCard extends StatelessWidget {
  const _RecoveryRequiredCard();
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: const Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Recovery required. Journal metadata could not be authenticated. Existing ciphertext is retained or quarantined; clear Android app storage or reinstall only after accepting local data loss.',
      ),
    ),
  );
}

final class _NoTrustedSendersCard extends StatelessWidget {
  const _NoTrustedSendersCard();
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: const Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Automatic capture unavailable: no trusted sender is configured. Add one exact sender rule before relying on payment SMS capture.',
      ),
    ),
  );
}

final class _CaptureMissCard extends StatelessWidget {
  const _CaptureMissCard({required this.signal});
  final CaptureMissSignal signal;

  @override
  Widget build(BuildContext context) {
    final String reason = switch (signal) {
      CaptureMissSignal.overload => 'the receiver queue was full',
      CaptureMissSignal.expired => 'the receiver deadline expired',
    };
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Capture gap detected',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'A delivery may be missing because $reason. Existing inbox evidence remains available; reconcile provider records.',
            ),
          ],
        ),
      ),
    );
  }
}

final class _NativeErrorCard extends StatelessWidget {
  const _NativeErrorCard({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry inbox check'),
          ),
        ],
      ),
    ),
  );
}

final class _NativeSmsCard extends StatelessWidget {
  const _NativeSmsCard({
    required this.record,
    required this.busy,
    required this.onReviewed,
    required this.onRejected,
  });
  final NativeSmsRecord record;
  final bool busy;
  final VoidCallback onReviewed;
  final VoidCallback onRejected;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Trusted sender: ${record.sender}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(record.body, maxLines: 4, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          if (busy)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: onReviewed,
                  child: const Text('Reviewed — remove raw SMS'),
                ),
                OutlinedButton(
                  onPressed: onRejected,
                  child: const Text('Reject evidence'),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

final class _GemmaStatusCard extends StatelessWidget {
  const _GemmaStatusCard({required this.capability});
  final GemmaCapabilityEvidence capability;
  @override
  Widget build(BuildContext context) {
    final String detail = switch (capability) {
      GemmaUnavailable() => 'Unavailable on this device.',
      GemmaModelMissing() => 'No verified local model package is installed.',
      GemmaRuntimePending() =>
        'Native LiteRT-LM integration is pending verification.',
    };
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.auto_awesome_outlined),
                const SizedBox(width: 8),
                Text(
                  'Gemma 4 assistance',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '$detail Manual evidence review stays available; no SMS is uploaded. A model proposal can never create a payment.',
            ),
            const SizedBox(height: 10),
            Text(
              'Manual fallback active',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}

final class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.sender,
    required this.template,
    required this.error,
    required this.trustedSenders,
    required this.onSave,
  });
  final TextEditingController sender;
  final TextEditingController template;
  final String? error;
  final List<SenderIdentity> trustedSenders;
  final Future<void> Function() onSave;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Trusted sender rule',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Exact sender match only. Wildcards, regex and lookalike Unicode are refused.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: sender,
            decoration: const InputDecoration(
              labelText: 'Exact sender',
              hintText: '+243990001111 or ORANGE',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: template,
            decoration: const InputDecoration(
              labelText: 'Template',
              helperText: 'Only {amount}, {currency}, {reference}',
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (trustedSenders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Current exact rules: ${trustedSenders.map((SenderIdentity sender) => sender.value).join(', ')}',
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onSave,
            child: const Text('Store trusted rule securely'),
          ),
        ],
      ),
    ),
  );
}

final class _TrustedRuleStatus extends StatelessWidget {
  const _TrustedRuleStatus({
    required this.senders,
    required this.onRevoke,
    required this.onClear,
  });
  final List<SenderIdentity> senders;
  final Future<void> Function(SenderIdentity sender) onRevoke;
  final Future<void> Function() onClear;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.verified_user_outlined),
              SizedBox(width: 10),
              Expanded(child: Text('Trusted sender rules stored on device')),
            ],
          ),
          const SizedBox(height: 8),
          for (final SenderIdentity sender in senders)
            Row(
              children: <Widget>[
                Expanded(child: Text(sender.value)),
                TextButton(
                  onPressed: () => onRevoke(sender),
                  child: const Text('Revoke'),
                ),
              ],
            ),
          TextButton(
            onPressed: onClear,
            child: const Text('Clear all trusted senders'),
          ),
        ],
      ),
    ),
  );
}

final class _EmptyReview extends StatelessWidget {
  const _EmptyReview();
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.inbox_outlined, size: 32),
          const SizedBox(height: 12),
          Text(
            'No local evidence yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'No trusted SMS is waiting. Manual templates configure parsing; they do not bypass capture or create payment evidence.',
          ),
        ],
      ),
    ),
  );
}
