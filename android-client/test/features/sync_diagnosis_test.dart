import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/domain/sync_diagnosis.dart';
import 'package:opencongopay/features/sync_diagnosis/presentation/sync_diagnosis_card.dart';

void main() {
  test('diagnosis fails closed in dependency order and never confirms payment', () {
    const SyncCapabilityEvidence unavailableIdentity = SyncCapabilityEvidence(
      identityAuthorityApproved: false,
      transportAvailable: true,
      durableOutboxTested: true,
      acknowledgementAvailable: true,
    );
    final SyncDiagnosis identity = SyncDiagnosis.fromEvidence(unavailableIdentity);
    expect(identity.code, SyncDiagnosisCode.identityAuthorityUnapproved);
    expect(identity.localCaptureAvailable, isTrue);
    expect(identity.serverAcknowledgementAvailable, isFalse);

    final SyncDiagnosis transport = SyncDiagnosis.fromEvidence(const SyncCapabilityEvidence(
      identityAuthorityApproved: true,
      transportAvailable: false,
      durableOutboxTested: true,
      acknowledgementAvailable: true,
    ));
    expect(transport.code, SyncDiagnosisCode.transportUnavailable);

    final SyncDiagnosis outbox = SyncDiagnosis.fromEvidence(const SyncCapabilityEvidence(
      identityAuthorityApproved: true,
      transportAvailable: true,
      durableOutboxTested: false,
      acknowledgementAvailable: true,
    ));
    expect(outbox.code, SyncDiagnosisCode.durableOutboxUnverified);

    final SyncDiagnosis acknowledgement = SyncDiagnosis.fromEvidence(const SyncCapabilityEvidence(
      identityAuthorityApproved: true,
      transportAvailable: true,
      durableOutboxTested: true,
      acknowledgementAvailable: false,
    ));
    expect(acknowledgement.code, SyncDiagnosisCode.acknowledgementUnavailable);

    final SyncDiagnosis checking = SyncDiagnosis.fromEvidence(const SyncCapabilityEvidence(
      identityAuthorityApproved: true,
      transportAvailable: true,
      durableOutboxTested: true,
      acknowledgementAvailable: true,
    ));
    expect(checking.code, SyncDiagnosisCode.checkingReadiness);
    expect(checking.needsOperationalProbe, isTrue);
    expect(checking.serverAcknowledgementAvailable, isFalse);
  });

  testWidgets('card exposes unavailable sync without claiming payment confirmation', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final SyncDiagnosis diagnosis = SyncDiagnosis.fromEvidence(const SyncCapabilityEvidence(
      identityAuthorityApproved: false,
      transportAvailable: false,
      durableOutboxTested: false,
      acknowledgementAvailable: false,
    ));

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SyncDiagnosisCard(diagnosis: diagnosis))));

    expect(find.text('Server sync unavailable'), findsOneWidget);
    expect(find.textContaining('Local capture remains available'), findsOneWidget);
    expect(find.textContaining('confirmed'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics &&
            widget.properties.label ==
                'Server sync unavailable. Local capture remains available. Server acknowledgement is unavailable until identity authority is approved.',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
