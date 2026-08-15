import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/app_lock/domain/app_lock.dart';
import 'package:opencongopay/features/app_lock/presentation/app_lock_gate.dart';

final class AlwaysUnlocks implements LocalAppAuthenticator {
  @override
  Future<bool> authenticate() async => true;
}

final class NeverPins implements LocalPinVerifier {
  @override
  Future<bool> verify(String pin) async => false;
}

void main() {
  testWidgets('payment sales and sync content are never built or semantically exposed while locked', (
    WidgetTester tester,
  ) async {
    final AppLockController controller = AppLockController(
      authenticator: AlwaysUnlocks(),
      pinVerifier: NeverPins(),
    );
    int protectedBuilds = 0;
    final SemanticsHandle semantics = tester.ensureSemantics();
    final Finder lockRoute = find.byWidgetPredicate(
      (Widget widget) =>
          widget is Semantics && widget.properties.label == 'App locked',
    );
    final Finder protectedSemantics = find.byWidgetPredicate(
      (Widget widget) =>
          widget is Semantics &&
          widget.properties.label == 'Payment sales and sync content',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AppLockGate(
          controller: controller,
          now: () => DateTime.utc(2026, 8, 15, 10),
          protectedBuilder: (BuildContext context) {
            protectedBuilds++;
            return Semantics(
              label: 'Payment sales and sync content',
              child: Text('private payment content'),
            );
          },
        ),
      ),
    );

    expect(protectedBuilds, 0);
    expect(find.text('private payment content'), findsNothing);
    expect(protectedSemantics, findsNothing);
    expect(lockRoute, findsOneWidget);

    await tester.tap(find.text('Unlock app'));
    await tester.pumpAndSettle();
    expect(protectedBuilds, 1);
    expect(protectedSemantics, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(controller.snapshot.state, AppLockState.locked);
    expect(find.text('private payment content'), findsNothing);
    expect(protectedSemantics, findsNothing);
    expect(lockRoute, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.snapshot.state, AppLockState.locked);
    expect(find.text('private payment content'), findsNothing);
    semantics.dispose();
  });
}
