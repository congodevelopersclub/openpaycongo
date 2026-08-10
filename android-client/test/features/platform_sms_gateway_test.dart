import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';
import 'package:opencongopay/features/sms_gateway/infrastructure/platform_sms_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('test/sms_gateway');
  final PlatformSmsGateway gateway = PlatformSmsGateway(channel);
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'permissionState' => 'granted',
            'accessGeneration' => 7,
            'captureHealth' => <String, Object?>{
              'fault': 'capacity',
              'occurred_at_ms': 2000000000000,
              'decision_count': 1,
              'decision_encrypted_bytes': 96,
              'missed': 'overload',
              'missed_at_ms': 2000000000002,
              'recovery_required': false,
            },
            'probeStorage' => true,
            'listTrustedSenders' => <String>['ORANGE'],
            'addTrustedSender' => <String>['ORANGE'],
            'clearTrustedSenders' => <String>[],
            'revokeTrustedSender' => <String>[],
            'exportDecisions' => <String, Object?>{
              'records': <Map<String, Object>>[
                <String, Object>{
                  'id': 'a' * 43,
                  'decision': 'reviewed',
                  'decided_at_ms': 2000000000001,
                },
              ],
              'next_cursor': null,
              'truncated': false,
            },
            'drainInbox' => <Map<String, Object>>[
              <String, Object>{
                'id': 'a' * 43,
                'sender': 'ORANGE',
                'received_at_ms': 2000000000000,
                'segments': 1,
                'body': 'trusted bounded body',
              },
            ],
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'maps permission and typed records, syncs and acknowledges explicitly',
    () async {
      expect(await gateway.permissionState(), SmsAccessState.granted);
      final int generation = await gateway.accessGeneration();
      await gateway.setUnlocked(true, generation: generation);
      expect(await gateway.addTrustedSender('ORANGE'), <String>['ORANGE']);
      expect(await gateway.listTrustedSenders(), <String>['ORANGE']);
      final List<NativeSmsRecord> records = await gateway.drainInbox();
      expect(records.single.sender, 'ORANGE');
      final NativeCaptureHealth health = await gateway.captureHealth();
      expect(health.fault, CaptureFault.capacity);
      expect(health.decisionCount, 1);
      expect(health.missed, CaptureMissSignal.overload);
      expect(await gateway.probeStorage(), isTrue);
      expect((await gateway.exportDecisions()).records.single.decision,
          NativeCaptureDecision.reviewed);
      await gateway.commitInboxDecision(
        records.single.id,
        NativeCaptureDecision.reviewed,
      );
      expect(calls.map((MethodCall call) => call.method), <String>[
        'permissionState',
        'accessGeneration',
        'setUnlocked',
        'addTrustedSender',
        'listTrustedSenders',
        'drainInbox',
        'captureHealth',
        'probeStorage',
        'exportDecisions',
        'commitInboxDecision',
      ]);
    },
  );

  test('rejects invalid decision id before native deletion', () async {
    expect(
      () =>
          gateway.commitInboxDecision('short', NativeCaptureDecision.reviewed),
      throwsFormatException,
    );
    expect(calls, isEmpty);
  });

  test('rejects oversized or malformed native record fields', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method != 'drainInbox') return null;
          return <Map<String, Object>>[
            <String, Object>{
              'id': '!' * 43,
              'sender': 'ORANGE',
              'received_at_ms': 2000000000000,
              'segments': 1,
              'body': 'x' * 4097,
            },
          ];
        });
    expect(gateway.drainInbox(), throwsFormatException);
  });

  test('null drain export and probe are typed failures, never empty success', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    expect(gateway.drainInbox(), throwsFormatException);
    expect(gateway.exportDecisions(), throwsFormatException);
    expect(gateway.probeStorage(), throwsFormatException);
  });

  test('rejects non-E164 zero country code before syncing rule', () async {
    expect(
      () => gateway.addTrustedSender('+0234990001111'),
      throwsFormatException,
    );
  });

  test('decision pages require deep unique forward progress', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method != 'exportDecisions') return null;
          return <String, Object?>{
            'records': <Object?>[],
            'next_cursor': 'v3:0:0',
            'truncated': true,
          };
        });
    expect(gateway.exportDecisions(), throwsFormatException);
  });

  test('recovery health requires unknown journal counts, never fake zero', () async {
    Future<Object?> handler(MethodCall call, {required bool fakeZero}) async {
      if (call.method != 'captureHealth') return null;
      return <String, Object?>{
        'fault': 'corruption',
        'occurred_at_ms': null,
        'decision_count': fakeZero ? 0 : null,
        'decision_encrypted_bytes': fakeZero ? 0 : null,
        'missed': null,
        'missed_at_ms': null,
        'recovery_required': true,
      };
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall call) => handler(call, fakeZero: false),
        );
    final NativeCaptureHealth recovery = await gateway.captureHealth();
    expect(recovery.recoveryRequired, isTrue);
    expect(recovery.decisionCount, isNull);
    expect(recovery.occurredAt, isNull);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall call) => handler(call, fakeZero: true),
        );
    expect(gateway.captureHealth(), throwsFormatException);
  });
}
