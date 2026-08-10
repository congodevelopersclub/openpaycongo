import 'package:flutter/material.dart';

import '../domain/payment_ingestion.dart';

/// Volatile review evidence. No confirmed payment state: native capture,
/// encrypted storage and sync are not wired in this prototype.
final class ReviewEvidence {
  const ReviewEvidence({
    required this.sender,
    required this.summary,
    required this.createdAt,
    required this.state,
    required this.reason,
  });
  final String sender;
  final String summary;
  final DateTime createdAt;
  final ReviewState state;
  final String reason;
}

final class PaymentInboxScreen extends StatefulWidget {
  const PaymentInboxScreen({
    super.key,
    this.smsPermissionState = SmsPermissionState.needsDefaultRole,
    this.gemmaCapability = const GemmaRuntimePending(),
  });
  final SmsPermissionState smsPermissionState;
  final GemmaCapabilityEvidence gemmaCapability;
  @override
  State<PaymentInboxScreen> createState() => _PaymentInboxScreenState();
}

final class _PaymentInboxScreenState extends State<PaymentInboxScreen> {
  final TextEditingController _sender = TextEditingController();
  final TextEditingController _template = TextEditingController(
    text: '{amount} {currency} {reference}',
  );
  final TextEditingController _evidenceSender = TextEditingController();
  final TextEditingController _evidenceSummary = TextEditingController();
  final List<ReviewEvidence> _review = <ReviewEvidence>[];
  SenderIdentity? _trustedSender;
  String? _setupError;
  bool _showSetup = false;

  @override
  void dispose() {
    _sender.dispose();
    _template.dispose();
    _evidenceSender.dispose();
    _evidenceSummary.dispose();
    super.dispose();
  }

  void _saveRule() {
    final SenderIdentity? sender = SenderIdentity.fromOsMetadata(_sender.text);
    final PaymentTemplate template = PaymentTemplate(_template.text.trim());
    if (sender == null) {
      setState(
        () => _setupError =
            'Use an exact E.164 number or 3–11 character capital ASCII sender ID.',
      );
      return;
    }
    if (!template.valid) {
      setState(
        () => _setupError =
            'Template uses only {amount}, {currency}, {reference}.',
      );
      return;
    }
    setState(() {
      _trustedSender = sender;
      _setupError = null;
      _showSetup = false;
    });
  }

  void _addReviewEvidence() {
    final String sender = _evidenceSender.text.trim();
    final String summary = _evidenceSummary.text.trim();
    if (sender.isEmpty || summary.isEmpty) return;
    final SenderIdentity? identity = SenderIdentity.fromOsMetadata(sender);
    setState(() {
      _review.insert(
        0,
        ReviewEvidence(
          sender: sender,
          summary: summary,
          createdAt: DateTime.now().toUtc(),
          state: identity == null
              ? ReviewState.rejected
              : ReviewState.needsReview,
          reason: identity == null
              ? 'Invalid sender identity'
              : 'Manual sender is not OS-verified',
        ),
      );
      _evidenceSender.clear();
      _evidenceSummary.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
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
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            _CaptureStatusCard(state: widget.smsPermissionState),
            const SizedBox(height: 12),
            _GemmaStatusCard(capability: widget.gemmaCapability),
            if (_trustedSender != null) ...<Widget>[
              const SizedBox(height: 12),
              _TrustedRuleStatus(sender: _trustedSender!),
            ],
            if (_showSetup) ...<Widget>[
              const SizedBox(height: 20),
              _SetupCard(
                sender: _sender,
                template: _template,
                error: _setupError,
                trustedSender: _trustedSender,
                onSave: _saveRule,
              ),
            ],
            const SizedBox(height: 28),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Needs your review',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(
                  '${_review.length}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_review.isEmpty)
              _EmptyReview(onManualEvidence: () => _openManualEvidence(context))
            else ...<Widget>[
              for (final ReviewEvidence evidence in _review)
                _ReviewCard(evidence: evidence),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _openManualEvidence(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add manual evidence'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openManualEvidence(
    BuildContext context,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Add evidence for review',
            style: Theme.of(sheetContext).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Manual evidence never credits a wallet. Confirm against provider evidence before creating an event.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _evidenceSender,
            maxLength: 16,
            decoration: const InputDecoration(
              labelText: 'Sender shown by provider',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _evidenceSummary,
            maxLength: 512,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Redacted evidence summary',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              _addReviewEvidence();
              if (_evidenceSender.text.isEmpty &&
                  _evidenceSummary.text.isEmpty) {
                Navigator.pop(sheetContext);
              }
            },
            child: const Text('Keep for review'),
          ),
        ],
      ),
    ),
  );
}

final class _CaptureStatusCard extends StatelessWidget {
  const _CaptureStatusCard({required this.state});
  final SmsPermissionState state;
  @override
  Widget build(BuildContext context) {
    final bool blocked =
        state == SmsPermissionState.needsDefaultRole ||
        state == SmsPermissionState.unavailable;
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
                  ? 'Unavailable here. Android default SMS handler role is required; this prototype does not request restricted SMS access.'
                  : 'Capture capability requires native verification before it can be used.',
            ),
          ],
        ),
      ),
    );
  }
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
    required this.trustedSender,
    required this.onSave,
  });
  final TextEditingController sender;
  final TextEditingController template;
  final String? error;
  final SenderIdentity? trustedSender;
  final VoidCallback onSave;
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
          if (trustedSender != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Current exact rule: ${trustedSender!.value}'),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onSave,
            child: const Text('Validate rule locally'),
          ),
        ],
      ),
    ),
  );
}

final class _TrustedRuleStatus extends StatelessWidget {
  const _TrustedRuleStatus({required this.sender});
  final SenderIdentity sender;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: <Widget>[
          const Icon(Icons.verified_user_outlined),
          const SizedBox(width: 10),
          Expanded(child: Text('Trusted sender rule: ${sender.value}')),
        ],
      ),
    ),
  );
}

final class _EmptyReview extends StatelessWidget {
  const _EmptyReview({required this.onManualEvidence});
  final VoidCallback onManualEvidence;
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
            'Capture is unavailable until native role support is verified. Add redacted evidence manually for review.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onManualEvidence,
            child: const Text('Add manual evidence'),
          ),
        ],
      ),
    ),
  );
}

final class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.evidence});
  final ReviewEvidence evidence;
  @override
  Widget build(BuildContext context) {
    final bool rejected = evidence.state == ReviewState.rejected;
    return Card(
      child: ListTile(
        leading: Icon(
          rejected ? Icons.block_outlined : Icons.pending_actions_outlined,
        ),
        title: Text(rejected ? 'Rejected evidence' : 'Review required'),
        subtitle: Text(
          '${evidence.reason}\n${evidence.sender}\n${evidence.summary}',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}
