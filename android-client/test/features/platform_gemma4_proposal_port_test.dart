import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_inbox/domain/payment_ingestion.dart';
import 'package:opencongopay/features/payment_inbox/infrastructure/platform_gemma4_proposal_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('test/gemma4');

  test('passes a bounded trusted SMS only over the local native channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'proposeGemma4Payment');
      expect(call.arguments, <String, String>{
        'sender': 'ORANGE',
        'body': 'Format changed',
      });
      return '{"amount_minor":1250}';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final SmsEnvelope sms = SmsEnvelope.fromOs(
      sender: SenderIdentity.fromOsMetadata('ORANGE')!,
      body: 'Format changed',
      receivedAt: DateTime.utc(2026, 9, 6),
      segments: 1,
      now: DateTime.utc(2026, 9, 6),
    )!;

    expect(
      await PlatformGemma4ProposalPort(channel).proposeJson(
        sms,
        const Duration(seconds: 3),
      ),
      '{"amount_minor":1250}',
    );
  });
}
