import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/platform_pairing_directional_key_vault.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'openpaycongo/pairing_directional_keys',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('copies exactly two directional keys for native vault then wipes copies',
      () async {
    Map<Object?, Object?>? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'save');
          received = (call.arguments as Map<Object?, Object?>).map(
            (Object? key, Object? value) => MapEntry<Object?, Object?>(
              key,
              value is Uint8List ? Uint8List.fromList(value) : value,
            ),
          );
          return null;
        });
    final PairingDirectionalKeys keys = PairingDirectionalKeys(
      sendKey: Uint8List.fromList(List<int>.filled(32, 1)),
      receiveKey: Uint8List.fromList(List<int>.filled(32, 2)),
    );

    await const PlatformPairingDirectionalKeyVault().save(keys);

    expect(received!.keys, unorderedEquals(<String>['send_key', 'receive_key']));
    expect(received!['send_key'], Uint8List.fromList(List<int>.filled(32, 1)));
    expect(
      received!['receive_key'],
      Uint8List.fromList(List<int>.filled(32, 2)),
    );
    keys.dispose();
  });

  test('fails closed when native secure storage rejects key handoff', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall _) async {
          throw PlatformException(code: 'secure_storage_failure');
        });
    final PairingDirectionalKeys keys = PairingDirectionalKeys(
      sendKey: Uint8List(32),
      receiveKey: Uint8List(32),
    );

    await expectLater(
      const PlatformPairingDirectionalKeyVault().save(keys),
      throwsA(isA<StateError>()),
    );
    keys.dispose();
  });
}
