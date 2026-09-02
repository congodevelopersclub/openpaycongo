import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/platform_pairing_activation_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('openpaycongo/pairing_activation');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('returns only redacted activation outcome', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'consume');
          expect((call.arguments as Map<Object?, Object?>).keys, unorderedEquals(<String>[
            'intent_id',
            'nonce',
            'ciphertext',
          ]));
          return 'activated';
        });

    final PairingActivationConsumeResult result = await const PlatformPairingActivationVault().consume(
      intentId: Uint8List(16),
      nonce: Uint8List(24),
      ciphertext: Uint8List.fromList(<int>[1, 2, 3]),
    );

    expect(result, PairingActivationConsumeResult.activated);
    expect(result.toString(), isNot(contains('bearer')));
  });
}
