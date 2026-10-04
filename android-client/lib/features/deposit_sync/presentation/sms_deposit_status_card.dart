import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'deposit_submission_bloc.dart';
import 'sms_deposit_coordinator.dart';

final class SmsDepositStatusCard extends StatelessWidget {
  const SmsDepositStatusCard({super.key, required this.coordinator, required this.onRefreshInbox});
  final SmsDepositCoordinator coordinator;
  final VoidCallback onRefreshInbox;

  @override
  Widget build(BuildContext context) => BlocConsumer<SmsDepositCoordinator, SmsDepositSyncStatus>(
    bloc: coordinator,
    listener: (_, status) {
      if (status != SmsDepositSyncStatus.syncing) onRefreshInbox();
    },
    builder: (_, status) => Card(child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('SMS deposit sync', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('A signed parser and exact trusted sender are required. Reported deposits create provisional credit; settlement remains unverified.'),
        const SizedBox(height: 8),
        const Text('Before receiving operator SMS, use Review rules to register its exact sender. Importing a signed parser does not change your sender rules.'),
        const SizedBox(height: 8),
        Text(switch (status) {
          SmsDepositSyncStatus.idle => 'Waiting for captured SMS. Pending sends retry every 30 seconds while unlocked.',
          SmsDepositSyncStatus.syncing => 'Checking retained SMS and pending sends.',
          SmsDepositSyncStatus.reviewRequired => 'Some messages need review or a current signed parser. Their raw evidence is retained.',
          SmsDepositSyncStatus.queued => 'Parsed evidence transferred to the encrypted deposit queue.',
          SmsDepositSyncStatus.storageUnavailable => 'Secure storage is unavailable. Retained evidence needs recovery before sync can continue.',
        }),
        const SizedBox(height: 8),
        BlocBuilder<DepositSubmissionBloc, DepositSubmissionState>(bloc: coordinator.submissions,
          builder: (_, state) => Text(switch (state) {
            DepositSubmissionRecorded() => 'Server recorded provisional credit. Settlement is unverified.',
            DepositSubmissionReplayed() => 'Server recognized an existing deposit. No duplicate credit was created.',
            DepositSubmissionConflict() => 'Server rejected conflicting evidence. The encrypted request is retained for recovery.',
            DepositSubmissionRetryableFailure() => 'No authenticated acknowledgement received. The encrypted request remains pending.',
            DepositSubmissionPersistenceFailure() => 'Encrypted queue update failed. Recovery is required.',
            DepositSubmissionSubmitting() => 'Sending paired encrypted evidence.',
            DepositSubmissionIdle() => 'No submission result in this session.',
          })),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: <Widget>[
          OutlinedButton(onPressed: status == SmsDepositSyncStatus.syncing ? null : () => coordinator.sync(),
            child: const Text('Retry sync')),
          OutlinedButton(onPressed: status == SmsDepositSyncStatus.syncing ? null : () => _install(context),
            child: const Text('Import signed parser')),
        ]),
      ]))));

  Future<void> _install(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    final String? bundle = await showDialog<String>(context: context, builder: (BuildContext context) => AlertDialog(
      title: const Text('Import signed operator parser'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        const Text('Paste the administrator-published release bundle. Its signing key must match this installation\'s paired server. No new trust pin is accepted here.'),
        const SizedBox(height: 12),
        TextField(controller: controller, maxLength: 12288, maxLines: 6,
          decoration: const InputDecoration(labelText: 'Signed release bundle')),
      ])),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Verify and install')),
      ]));
    controller.dispose();
    if (bundle == null) return;
    final bool accepted = await coordinator.installRelease(bundle);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(accepted
        ? 'Signed parser installed. Retained messages were checked.'
        : 'Parser refused. Check its signature, paired signing authority, required fields, expiry, and version.')));
  }
}
