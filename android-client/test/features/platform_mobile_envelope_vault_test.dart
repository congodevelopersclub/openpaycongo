import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/infrastructure/platform_mobile_envelope_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('openpaycongo/mobile_envelope');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('passes only deposit payload then returns routing-safe envelope', () async {
    final Uint8List payload = Uint8List.fromList('{"amount_minor":1250}'.codeUnits);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'seal');
          expect(call.arguments, <String, Object>{'operation': 'deposit', 'payload': payload});
          return <String, Object>{
            'version': 1,
            'installation_id': '123e4567-e89b-12d3-a456-426614174000',
            'counter': '1',
            'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            'ciphertext': 'opaque-ciphertext',
          };
        });

    final MobileRequestEnvelope envelope = await const PlatformMobileEnvelopeVault().sealDeposit(payload);

    expect(envelope.counter, '1');
    expect(envelope.ciphertext, 'opaque-ciphertext');
    expect(payload, everyElement(0));
  });

  test('maps native failure without payload details', () async {
    final Uint8List payload = Uint8List.fromList('{"private":"value"}'.codeUnits);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'envelope_unavailable'));

    await expectLater(const PlatformMobileEnvelopeVault().sealDeposit(payload), throwsA(isA<StateError>()));
    expect(payload, everyElement(0));
  });
}
