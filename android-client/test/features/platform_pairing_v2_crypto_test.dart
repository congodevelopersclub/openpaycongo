import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/platform_pairing_v2_crypto.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('openpaycongo/pairing_completion');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('begin transfers QR secret plus public QR data; accept exposes SAS only', () async {
    final Uint8List secret = Uint8List.fromList(List<int>.filled(32, 7));
    final PairingV2QrCredential credential = PairingV2QrCredential(
      intentId: 'AAAAAAAAAAAAAAAAAAAAAA',
      serverPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      pairingSecret: secret,
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'begin') {
            final Map<Object?, Object?> arguments = call.arguments as Map<Object?, Object?>;
            expect(arguments.keys, unorderedEquals(<String>[
              'intent_id', 'server_public_key', 'pairing_secret',
            ]));
            expect(arguments['pairing_secret'], Uint8List.fromList(List<int>.filled(32, 7)));
            return <String, String>{
              'intent_id': 'AAAAAAAAAAAAAAAAAAAAAA',
              'client_public_key': 'client-public-key',
              'nonce': 'nonce',
              'ciphertext': 'ciphertext',
            };
          }
          if (call.method == 'accept') {
            expect(call.arguments, <String, String>{
              'intent_id': 'AAAAAAAAAAAAAAAAAAAAAA',
              'nonce': 'server-nonce',
              'ciphertext': 'server-ciphertext',
            });
            return '482901';
          }
          return null;
        });

    final PlatformPairingV2Crypto crypto = PlatformPairingV2Crypto();
    final PairingV2Request request = await crypto.begin(credential);
    expect(secret, everyElement(0));
    expect(request.clientPublicKey, 'client-public-key');
    expect(await crypto.accept(const PairingV2Response(nonce: 'server-nonce', ciphertext: 'server-ciphertext')), '482901');
    expect(calls.map((MethodCall call) => call.method), <String>['begin', 'accept']);
  });

  test('malformed native output fails closed and wipes transferred QR secret', () async {
    final Uint8List secret = Uint8List.fromList(List<int>.filled(32, 3));
    final PairingV2QrCredential credential = PairingV2QrCredential(
      intentId: 'AAAAAAAAAAAAAAAAAAAAAA',
      serverPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      pairingSecret: secret,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => <String, String>{
              'intent_id': 'AAAAAAAAAAAAAAAAAAAAAA',
              'client_public_key': 'public',
              'nonce': 'nonce',
            });

    await expectLater(PlatformPairingV2Crypto().begin(credential), throwsA(isA<StateError>()));
    expect(secret, everyElement(0));
    expect(credential.takePairingSecret, throwsStateError);
  });

  test('native errors fail closed; cancel is best effort', () async {
    final PlatformPairingV2Crypto crypto = PlatformPairingV2Crypto();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'cancel') throw PlatformException(code: 'unavailable');
          throw PlatformException(code: 'unavailable');
        });
    await expectLater(
      crypto.accept(const PairingV2Response(nonce: 'nonce', ciphertext: 'ciphertext')),
      throwsA(isA<StateError>()),
    );
    await crypto.dispose();
  });
}
