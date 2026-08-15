import 'package:flutter/material.dart';

import '../domain/sync_diagnosis.dart';

/// Presents capability evidence without making a public support or payment
/// confirmation claim.
final class SyncDiagnosisCard extends StatelessWidget {
  const SyncDiagnosisCard({required this.diagnosis, super.key});

  final SyncDiagnosis diagnosis;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${diagnosis.title}. ${diagnosis.detail}',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(diagnosis.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(diagnosis.detail),
            ],
          ),
        ),
      ),
    );
  }
}
