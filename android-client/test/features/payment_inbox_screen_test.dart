import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/payment_ingestion.dart';
import 'package:opencongopay/features/payment_inbox/presentation/payment_inbox_screen.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_session_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_enrollment_bloc.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:opencongopay/features/payment_outbox/presentation/payment_lifecycle_bloc.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';
import 'package:opencongopay/features/sync_diagnosis/presentation/sync_cursor_bloc.dart';
import 'package:opencongopay/widgets/opencongopayapp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel smsChannel = MethodChannel('openpaycongo/sms_gateway');
  const MethodChannel appLockChannel = MethodChannel('openpaycongo/app_lock');
  const MethodChannel localAuthChannel = MethodChannel(
    'plugins.flutter.io/local_auth',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appLockChannel, (MethodCall call) async {
          if (call.method == 'status') return 'ready';
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, (MethodCall call) async {
          return switch (call.method) {
            'permissionState' => 'granted',
            'accessGeneration' => 1,
            'captureHealth' => <String, Object?>{
              'fault': null,
              'occurred_at_ms': null,
              'decision_count': 0,
              'decision_encrypted_bytes': 0,
              'missed': null,
              'missed_at_ms': null,
              'recovery_required': false,
            },
            'drainInbox' => <Object?>[],
            'listTrustedSenders' => <Object?>[],
            'exportDecisions' => <String, Object?>{
              'records': <Object?>[],
              'next_cursor': null,
              'truncated': false,
            },
            _ => null,
          };
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(localAuthChannel, (MethodCall call) async {
          if (call.method == 'authenticate') return true;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appLockChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(localAuthChannel, null);
  });

  Widget app({
    SmsGatewayPort? gateway,
    GemmaCapabilityEvidence capability = const GemmaRuntimePending(),
    PaymentLifecycleBloc? paymentLifecycle,
    PairingEnrollmentBloc? pairingEnrollment,
    PairingSessionBloc? pairingSession,
    SyncCursorBloc? syncCursor,
  }) => MaterialApp(
    home: PaymentInboxScreen(
      gateway: gateway ?? _FakeGateway(),
      gemmaCapability: capability,
      paymentLifecycle: paymentLifecycle,
      pairingEnrollment: pairingEnrollment,
      pairingSession: pairingSession,
      syncCursor: syncCursor,
    ),
  );

  testWidgets('composes injected pairing BLoC into the production inbox', (
    tester,
  ) async {
    final PairingSessionBloc pairing = PairingSessionBloc(
      store: _PairingStore(),
      gateway: _PairingGateway(),
      telemetry: _PairingTelemetry(),
    );
    addTearDown(pairing.close);
    await tester.pumpWidget(app(pairingSession: pairing));
    pairing.add(const PairingSessionStarted());
    await tester.pumpAndSettle();
    expect(find.text('Pairing awaits confirmation'), findsOneWidget);
  });

  testWidgets('app composition passes injected pairing BLoC to its inbox', (
    WidgetTester tester,
  ) async {
    final PairingSessionBloc pairing = PairingSessionBloc(
      store: _PairingStore(),
      gateway: _PairingGateway(),
      telemetry: _PairingTelemetry(),
    );
    addTearDown(pairing.close);

    await tester.pumpWidget(OpenCongoPayApp(pairingSession: pairing));
    await _unlockApp(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    pairing.add(const PairingSessionStarted());
    await tester.pumpAndSettle();

    expect(find.text('Pairing awaits confirmation'), findsOneWidget);
  });

  testWidgets('app composition passes injected enrollment BLoC to its inbox', (
    WidgetTester tester,
  ) async {
    final PairingEnrollmentBloc enrollment = PairingEnrollmentBloc(
      store: _EnrollmentStore(),
      transport: _EnrollmentTransport(),
      telemetry: _EnrollmentTelemetry(),
    );
    addTearDown(enrollment.close);

    await tester.pumpWidget(OpenCongoPayApp(pairingEnrollment: enrollment));
    await _unlockApp(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    enrollment.add(const PairingEnrollmentStarted());
    await tester.pumpAndSettle();

    expect(find.text('Pairing enrollment awaits confirmation'), findsOneWidget);
  });

  testWidgets('app composition passes injected sync BLoC to its inbox', (
    WidgetTester tester,
  ) async {
    final SyncCursorBloc sync = SyncCursorBloc(
      store: _SyncStore(),
      contract: _SyncContract(),
      telemetry: _SyncTelemetry(),
    );
    addTearDown(sync.close);

    await tester.pumpWidget(OpenCongoPayApp(syncCursor: sync));
    await _unlockApp(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    sync.add(const SyncCursorStarted());
    await tester.pumpAndSettle();

    expect(find.text('Sync cursor current'), findsOneWidget);
  });

  testWidgets(
    'composes the payment lifecycle status into the production inbox',
    (WidgetTester tester) async {
      final PaymentLifecycleBloc lifecycle = PaymentLifecycleBloc(
        lifecycle: _OfflinePaymentLifecycle(),
        now: () => DateTime.utc(2026, 8, 30, 10),
      );
      addTearDown(lifecycle.close);

      await tester.pumpWidget(app(paymentLifecycle: lifecycle));
      lifecycle.add(
        const PaymentLifecycleSyncRequested(
          OutboxScope(tenantId: 'tenant-001', deviceId: 'device-001'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Payment sync is offline'), findsOneWidget);
      expect(find.text('Retry sync'), findsOneWidget);
    },
  );

  testWidgets(
    'native trusted record leaves inbox only after durable decision',
    (WidgetTester tester) async {
      final _FakeGateway gateway = _FakeGateway(
        health: const NativeCaptureHealth(fault: CaptureFault.capacity),
        records: <NativeSmsRecord>[
          NativeSmsRecord(
            id: 'a' * 43,
            sender: 'ORANGE',
            receivedAt: DateTime.utc(2026, 8, 10),
            segments: 1,
            body: 'Paid 10 USD ref ABCD-1234',
          ),
        ],
      );
      await tester.pumpWidget(app(gateway: gateway));
      await tester.pumpAndSettle();
      expect(find.text('Critical capture fault'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Reviewed — remove raw SMS'),
        300,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(find.textContaining('Trusted sender: ORANGE'), findsOneWidget);
      await tester.tap(find.text('Reviewed — remove raw SMS'));
      await tester.pumpAndSettle();
      expect(gateway.decisions, <NativeCaptureDecision>[
        NativeCaptureDecision.reviewed,
      ]);
      expect(find.textContaining('Trusted sender: ORANGE'), findsNothing);
    },
  );

  testWidgets('failed durable decision keeps evidence and shows fault', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      failCommit: true,
      failListAfterMutationFailure: true,
      records: <NativeSmsRecord>[
        NativeSmsRecord(
          id: 'b' * 43,
          sender: 'AIRTEL',
          receivedAt: DateTime.utc(2026, 8, 10),
          segments: 1,
          body: 'Payment evidence',
        ),
      ],
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Reject evidence'), 300);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reject evidence'));
    await tester.pumpAndSettle();
    expect(find.text('Reject and remove raw SMS?'), findsOneWidget);
    await tester.tap(find.text('Confirm reject'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Trusted sender: AIRTEL'), findsNothing);
    expect(
      find.textContaining('Trusted sender state is unknown'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Authoritative reload also failed'),
      findsOneWidget,
    );
  });

  testWidgets('health refresh failure clears actionable evidence', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      failHealthAfterCommit: true,
      records: <NativeSmsRecord>[
        NativeSmsRecord(
          id: 'h' * 43,
          sender: 'AIRTEL',
          receivedAt: DateTime.utc(2026, 8, 10),
          segments: 1,
          body: 'Payment evidence',
        ),
      ],
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Reviewed — remove raw SMS'),
      300,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reviewed — remove raw SMS'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Trusted sender: AIRTEL'), findsNothing);
    expect(
      find.textContaining('Trusted sender state is unknown'),
      findsOneWidget,
    );
    expect(find.textContaining('Decision outcome is unknown'), findsOneWidget);
  });

  testWidgets('missed capture signal warns but does not block inbox', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      health: const NativeCaptureHealth(
        fault: null,
        missed: CaptureMissSignal.expired,
      ),
      records: <NativeSmsRecord>[
        NativeSmsRecord(
          id: 'm' * 43,
          sender: 'ORANGE',
          receivedAt: DateTime.utc(2026, 8, 10),
          segments: 1,
          body: 'Still readable',
        ),
      ],
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    expect(find.text('Capture gap detected'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Trusted sender: ORANGE'),
      300,
    );
    expect(find.textContaining('Trusted sender: ORANGE'), findsOneWidget);
  });

  testWidgets('manual evidence is not an SMS-permission bypass', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Add manual evidence'), findsNothing);
    expect(
      find.textContaining('Automatic capture unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('transient storage fault offers guarded recovery probe', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      health: const NativeCaptureHealth(fault: CaptureFault.storage),
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    expect(find.text('Retry storage check'), findsOneWidget);
    await tester.tap(find.text('Retry storage check'));
    await tester.pumpAndSettle();
    expect(gateway.probeCount, 1);
    expect(find.text('Critical capture fault'), findsNothing);
  });

  testWidgets('timed-out storage probe reloads authoritative fault state', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      health: const NativeCaptureHealth(fault: CaptureFault.storage),
      failProbe: true,
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry storage check'));
    await tester.pumpAndSettle();
    expect(find.text('Critical capture fault'), findsOneWidget);
    expect(find.textContaining('probe outcome is unknown'), findsOneWidget);
  });

  testWidgets(
    'failed initial rule load is unknown, never authoritative empty',
    (WidgetTester tester) async {
      final _FakeGateway gateway = _FakeGateway(failListAlways: true);
      await tester.pumpWidget(app(gateway: gateway));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -360));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Trusted sender state is unknown'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Automatic capture unavailable'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'probe never claims reload when authoritative reload also fails',
    (WidgetTester tester) async {
      final _FakeGateway gateway = _FakeGateway(
        health: const NativeCaptureHealth(fault: CaptureFault.storage),
        failProbe: true,
        failListAfterMutationFailure: true,
      );
      await tester.pumpWidget(app(gateway: gateway));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry storage check'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Authoritative reload also failed'),
        findsOneWidget,
      );
      expect(find.textContaining('capture health was reloaded'), findsNothing);
    },
  );

  testWidgets('exact trusted rule is stored through secure gateway callback', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway();
    await tester.pumpWidget(
      MaterialApp(home: PaymentInboxScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.enterText(find.byType(TextField).at(0), 'ORANGE');
    await tester.enterText(
      find.byType(TextField).at(1),
      'Paid {amount} {currency} ref {reference}',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Store trusted rule securely'));
    await tester.pump();
    expect(gateway.trustedSenders, <String>['ORANGE']);
  });

  testWidgets('rule add never claims reload when reconciliation fails', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      failAdd: true,
      failListAfterMutationFailure: true,
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'ORANGE');
    await tester.enterText(
      find.byType(TextField).at(1),
      'Paid {amount} {currency} ref {reference}',
    );
    await tester.tap(find.text('Store trusted rule securely'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Trusted sender state is unknown'),
      findsOneWidget,
    );
  });

  testWidgets('persisted trusted rules load and can be revoked or cleared', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      trustedSenders: <String>['+243990001111', 'ORANGE'],
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    expect(find.text('+243990001111'), findsOneWidget);
    expect(find.text('ORANGE'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Revoke').first, 300);
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke').first);
    await tester.pumpAndSettle();
    expect(gateway.trustedSenders, <String>['ORANGE']);
    await tester.scrollUntilVisible(
      find.text('Clear all trusted senders'),
      300,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all trusted senders'));
    await tester.pumpAndSettle();
    expect(gateway.trustedSenders, isEmpty);
    expect(
      find.textContaining('Automatic capture unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('rule revoke never claims reload when reconciliation fails', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      trustedSenders: <String>['ORANGE'],
      failRevoke: true,
      failListAfterMutationFailure: true,
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Revoke'), 300);
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Authoritative reload also failed'),
      findsOneWidget,
    );
  });

  testWidgets('rule clear never claims reload when reconciliation fails', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      trustedSenders: <String>['ORANGE'],
      failClear: true,
      failListAfterMutationFailure: true,
    );
    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Clear all trusted senders'),
      300,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all trusted senders'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Authoritative reload also failed'),
      findsOneWidget,
    );
  });

  testWidgets('journal control failure is an explicit recovery state', (
    WidgetTester tester,
  ) async {
    final _FakeGateway gateway = _FakeGateway(
      health: const NativeCaptureHealth(
        fault: CaptureFault.corruption,
        recoveryRequired: true,
      ),
      records: <NativeSmsRecord>[
        NativeSmsRecord(
          id: 'r' * 43,
          sender: 'ORANGE',
          receivedAt: DateTime.utc(2026, 8, 10),
          segments: 1,
          body: 'unreadable while recovery is required',
        ),
      ],
    );

    await tester.pumpWidget(app(gateway: gateway));
    await tester.pumpAndSettle();

    expect(find.textContaining('Recovery required'), findsOneWidget);
    expect(find.textContaining('Trusted sender: ORANGE'), findsNothing);
  });

  testWidgets('Gemma runtime pending cannot appear ready', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());
    expect(
      find.textContaining('integration is pending verification'),
      findsOneWidget,
    );
    expect(find.textContaining('can never create a payment'), findsOneWidget);
  });
}

Future<void> _unlockApp(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('Use biometrics'));
  await tester.pumpAndSettle();
}

final class _FakeGateway implements SmsGatewayPort {
  _FakeGateway({
    this.records = const <NativeSmsRecord>[],
    this.health = const NativeCaptureHealth(fault: null),
    this.failCommit = false,
    this.failHealthAfterCommit = false,
    this.failProbe = false,
    this.failListAlways = false,
    this.failListAfterMutationFailure = false,
    this.failAdd = false,
    this.failRevoke = false,
    this.failClear = false,
    List<String> trustedSenders = const <String>[],
  }) : trustedSenders = List<String>.of(trustedSenders);

  List<NativeSmsRecord> records;
  NativeCaptureHealth health;
  final bool failCommit;
  final bool failHealthAfterCommit;
  final bool failProbe;
  final bool failListAlways;
  final bool failListAfterMutationFailure;
  final bool failAdd;
  final bool failRevoke;
  final bool failClear;
  bool mutationFailed = false;
  bool committed = false;
  final List<NativeCaptureDecision> decisions = <NativeCaptureDecision>[];
  int probeCount = 0;
  List<String> trustedSenders;

  @override
  Future<NativeCaptureHealth> captureHealth() async {
    if (committed && failHealthAfterCommit) throw StateError('health');
    return health;
  }

  @override
  Future<bool> probeStorage() async {
    probeCount += 1;
    if (failProbe) {
      mutationFailed = true;
      throw StateError('probe timeout');
    }
    if (health.fault == CaptureFault.storage) {
      health = const NativeCaptureHealth(fault: null);
    }
    return true;
  }

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
  Future<List<NativeSmsRecord>> drainInbox() async => records;
  @override
  Future<void> commitInboxDecision(
    String id,
    NativeCaptureDecision decision,
  ) async {
    if (failCommit) {
      mutationFailed = true;
      throw StateError('disk');
    }
    decisions.add(decision);
    committed = true;
    records = records
        .where((NativeSmsRecord record) => record.id != id)
        .toList();
    health = const NativeCaptureHealth(fault: null);
  }

  @override
  Future<List<String>> addTrustedSender(String sender) async {
    if (failAdd) {
      mutationFailed = true;
      throw StateError('add timeout');
    }
    trustedSenders = (<String>{...trustedSenders, sender}.toList()..sort());
    return List<String>.of(trustedSenders);
  }

  @override
  Future<List<String>> listTrustedSenders() async =>
      failListAlways || (failListAfterMutationFailure && mutationFailed)
      ? throw StateError('list timeout')
      : List<String>.of(trustedSenders);
  @override
  Future<List<String>> clearTrustedSenders() async {
    if (failClear) {
      mutationFailed = true;
      throw StateError('clear timeout');
    }
    trustedSenders = <String>[];
    return const <String>[];
  }

  @override
  Future<List<String>> revokeTrustedSender(String sender) async {
    if (failRevoke) {
      mutationFailed = true;
      throw StateError('revoke timeout');
    }
    trustedSenders = trustedSenders
        .where((String value) => value != sender)
        .toList();
    return List<String>.of(trustedSenders);
  }

  @override
  Future<SmsAccessState> permissionState() async => SmsAccessState.granted;
  @override
  Future<SmsAccessState> requestPermission() async => SmsAccessState.granted;
  @override
  Future<void> openSettings() async {}
  @override
  Future<int> accessGeneration() async => 1;

  @override
  Future<void> setUnlocked(bool unlocked, {int? generation}) async {}
}

final class _OfflinePaymentLifecycle implements PaymentLifecycle {
  @override
  Future<PaymentLifecycleResult> sync(OutboxScope scope, DateTime now) async =>
      const PaymentLifecycleResult.offline();
}

final class _PairingStore implements PairingSessionStore {
  @override
  Future<void> clear() async {}
  @override
  Future<PairingSession?> load() async => null;
  @override
  Future<void> save(PairingSession session) async {}
}

final class _PairingGateway implements PairingSessionGateway {
  final PairingSession session = PairingSession(
    sessionId: 'opaque',
    phase: PairingPhase.pending,
    updatedAt: DateTime.utc(2026),
  );
  @override
  Future<PairingSession> begin() async => session;
  @override
  Future<PairingSession> refresh(String sessionId) async => session;
}

final class _PairingTelemetry implements PairingTelemetry {
  @override
  void record(PairingTelemetrySignal signal) {}
}

final class _EnrollmentStore implements PairingEnrollmentStore {
  @override
  Future<void> clear() async {}

  @override
  Future<PairingEnrollment?> load() async => null;

  @override
  Future<void> save(PairingEnrollment enrollment) async {}

  @override
  Future<PairingEnrollmentCleanup?> loadCleanup() async => null;

  @override
  Future<void> saveCleanup(PairingEnrollmentCleanup cleanup) async {}

  @override
  Future<void> clearCleanup() async {}
}

final class _EnrollmentTransport implements PairingEnrollmentTransport {
  final PairingEnrollment enrollment = PairingEnrollment(
    phase: PairingEnrollmentPhase.pendingConfirmation,
    updatedAt: DateTime.utc(2026, 8, 30),
  );

  @override
  Future<PairingEnrollment> begin() async => enrollment;

  @override
  Future<PairingEnrollment> recover(PairingEnrollment enrollment) async =>
      this.enrollment;

  @override
  Future<PairingEnrollment> retry(PairingEnrollment enrollment) async =>
      this.enrollment;

  @override
  Future<void> discardTerminal() async {}
}

final class _EnrollmentTelemetry implements PairingEnrollmentTelemetryPort {
  @override
  void record(PairingEnrollmentTelemetry signal) {}
}

final class _SyncStore implements SyncCursorStore {
  @override
  Future<SyncCursor?> load() async => null;

  @override
  Future<void> save(SyncCursor cursor) async {}

  @override
  Future<void> clear() async {}
}

final class _SyncContract implements SyncCursorContract {
  @override
  Future<SyncCursorReconciliation> reconcile(SyncCursor? durableCursor) async {
    return const SyncCursorReconciliation(
      cursor: SyncCursor('opaque-test-cursor'),
      health: SyncCursorHealth.current,
    );
  }

  @override
  Future<SyncCursorDeliveryDecision> classifyDelivery(
    SyncCursor? durableCursor,
    SyncCursor delivery,
  ) async => SyncCursorDeliveryDecision.accept;
}

final class _SyncTelemetry implements SyncCursorTelemetry {
  @override
  void record(SyncCursorTelemetrySignal signal) {}
}
