import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';
import 'package:opencongopay/features/sms_gateway/presentation/sms_permission_gate.dart';

void main() {
  testWidgets('protected product is never built before RECEIVE_SMS grant', (
    WidgetTester tester,
  ) async {
    final _FakeSmsGateway gateway = _FakeSmsGateway(SmsAccessState.denied);
    int builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SmsPermissionGate(
          gateway: gateway,
          protectedBuilder: (BuildContext context) {
            builds += 1;
            return const Text('private product');
          },
        ),
      ),
    );
    await tester.pump();
    expect(builds, 0);
    expect(find.text('Receive payment SMS'), findsOneWidget);
    expect(find.text('private product'), findsNothing);

    gateway.nextRequestState = SmsAccessState.granted;
    await tester.tap(find.text('Allow SMS capture'));
    await tester.pumpAndSettle();
    expect(builds, 1);
    expect(find.text('private product'), findsOneWidget);
  });

  testWidgets('permanent refusal offers settings and no bypass', (
    WidgetTester tester,
  ) async {
    final _FakeSmsGateway gateway = _FakeSmsGateway(
      SmsAccessState.permanentlyDenied,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SmsPermissionGate(
          gateway: gateway,
          protectedBuilder: (_) => const Text('private product'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Open app settings'), findsOneWidget);
    expect(
      find.textContaining('No payment content is available'),
      findsOneWidget,
    );
    expect(find.textContaining('manual'), findsNothing);
    await tester.tap(find.text('Open app settings'));
    expect(gateway.settingsOpened, isTrue);
  });

  testWidgets('resume immediately hides product and ignores stale checks', (
    WidgetTester tester,
  ) async {
    final _FakeSmsGateway gateway = _FakeSmsGateway(SmsAccessState.granted);
    await tester.pumpWidget(
      MaterialApp(
        home: SmsPermissionGate(
          gateway: gateway,
          protectedBuilder: (_) => const Text('private product'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('private product'), findsOneWidget);

    final Completer<SmsAccessState> staleRecheck = Completer<SmsAccessState>();
    final Completer<SmsAccessState> currentRecheck = Completer<SmsAccessState>();
    gateway.pendingPermissionStates.add(staleRecheck);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('private product'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gateway.pendingPermissionStates.add(currentRecheck);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    currentRecheck.complete(SmsAccessState.granted);
    await tester.pumpAndSettle();
    expect(find.text('private product'), findsOneWidget);

    staleRecheck.complete(SmsAccessState.denied);
    await tester.pumpAndSettle();
    expect(find.text('private product'), findsOneWidget);
  });
}

final class _FakeSmsGateway implements SmsGatewayPort {
  _FakeSmsGateway(this.currentState);
  SmsAccessState currentState;
  SmsAccessState? nextRequestState;
  bool settingsOpened = false;
  final List<Completer<SmsAccessState>> pendingPermissionStates =
      <Completer<SmsAccessState>>[];

  @override
  Future<SmsAccessState> permissionState() async {
    if (pendingPermissionStates.isNotEmpty) {
      return pendingPermissionStates.removeAt(0).future;
    }
    return currentState;
  }

  @override
  Future<SmsAccessState> requestPermission() async {
    currentState = nextRequestState ?? currentState;
    return currentState;
  }

  @override
  Future<void> openSettings() async => settingsOpened = true;

  @override
  Future<int> accessGeneration() async => 1;

  @override
  Future<void> setUnlocked(bool unlocked, {int? generation}) async {}

  @override
  Future<bool> probeStorage() async => true;

  @override
  Future<NativeDecisionPage> exportDecisions({
    int limit = 100,
    String? cursor,
  }) async => const NativeDecisionPage(
    records: <NativeDecisionRecord>[],
    nextCursor: null,
    truncated: false,
  );

  @override
  Future<List<String>> addTrustedSender(String sender) async => <String>[sender];
  @override
  Future<List<String>> listTrustedSenders() async => const <String>[];
  @override
  Future<List<String>> clearTrustedSenders() async => const <String>[];
  @override
  Future<List<String>> revokeTrustedSender(String sender) async => const <String>[];

  @override
  Future<NativeCaptureHealth> captureHealth() async =>
      const NativeCaptureHealth(fault: null);

  @override
  Future<List<NativeSmsRecord>> drainInbox() async => const <NativeSmsRecord>[];

  @override
  Future<void> commitInboxDecision(
    String id,
    NativeCaptureDecision decision,
  ) async {}
}
