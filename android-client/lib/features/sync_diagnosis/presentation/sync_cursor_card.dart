import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'sync_cursor_bloc.dart';

final class SyncCursorCard extends StatelessWidget {
  const SyncCursorCard({required this.bloc, super.key});

  final SyncCursorBloc bloc;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<SyncCursorBloc>.value(
      value: bloc,
      child: BlocBuilder<SyncCursorBloc, SyncCursorState>(
        builder: (BuildContext context, SyncCursorState state) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: switch (state) {
                SyncCursorLoading() => const Text('Checking sync'),
                SyncCursorEmpty() => const Text('No sync cursor'),
                SyncCursorSynced() => const Text('Sync cursor current'),
                SyncCursorStale() => const Text('Sync cursor is reconciling'),
                SyncCursorDegraded() => const Text('Sync is degraded'),
                SyncCursorOffline() => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('Sync offline'),
                    TextButton(
                      onPressed: () => context.read<SyncCursorBloc>().add(
                        const SyncCursorRetryRequested(),
                      ),
                      child: const Text('Retry sync'),
                    ),
                  ],
                ),
              },
            ),
          );
        },
      ),
    );
  }
}
