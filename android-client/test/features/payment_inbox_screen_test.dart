import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/payment_ingestion.dart';
import 'package:opencongopay/features/payment_inbox/presentation/payment_inbox_screen.dart';

void main() {
  Widget app({
    GemmaCapabilityEvidence capability = const GemmaRuntimePending(),
  }) => MaterialApp(home: PaymentInboxScreen(gemmaCapability: capability));

  testWidgets(
    'restricted SMS capture is off and manual review remains usable',
    (WidgetTester tester) async {
      await tester.pumpWidget(app());
      expect(
        find.textContaining('default SMS handler role is required'),
        findsOneWidget,
      );
      expect(
        find.textContaining('does not request restricted SMS access'),
        findsOneWidget,
      );
      expect(find.text('Why this is required'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Add manual evidence'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'ORANGE');
      await tester.enterText(
        find.byType(TextField).at(1),
        'Payment reference REDACTED',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Keep for review'));
      await tester.pumpAndSettle();
      expect(find.text('Review required'), findsOneWidget);
      expect(
        find.textContaining('Manual sender is not OS-verified'),
        findsOneWidget,
      );
    },
  );

  testWidgets('invalid manual sender is visibly rejected with reason', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Add manual evidence'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Orange');
    await tester.enterText(find.byType(TextField).at(1), 'Redacted evidence');
    await tester.tap(find.widgetWithText(FilledButton, 'Keep for review'));
    await tester.pumpAndSettle();
    expect(find.text('Rejected evidence'), findsOneWidget);
    expect(find.textContaining('Invalid sender identity'), findsOneWidget);
  });

  testWidgets(
    'exact trusted rule is visible but does not trust manual evidence',
    (WidgetTester tester) async {
      await tester.pumpWidget(app());
      await tester.tap(find.text('Review rules'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'ORANGE');
      await tester.enterText(
        find.byType(TextField).at(1),
        'Paid {amount} {currency} ref {reference}',
      );
      await tester.drag(find.byType(ListView), const Offset(0, -420));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Validate rule locally'),
      );
      await tester.pump();
      expect(
        find.textContaining('Trusted sender rule: ORANGE'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Gemma runtime pending cannot appear ready', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());
    expect(
      find.textContaining('integration is pending verification'),
      findsOneWidget,
    );
    expect(find.text('Manual fallback active'), findsOneWidget);
    expect(find.textContaining('can never create a payment'), findsOneWidget);
    expect(find.text('Review-only mode'), findsNothing);
  });
}
