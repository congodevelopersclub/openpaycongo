import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/platform_pairing_qr_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(
    'openpaycongo/pairing_qr_scanner',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('passes one bounded native QR result directly to the caller', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'scan');
          expect(call.arguments, isNull);
          return 'bounded-raw-qr';
        });

    expect(await const PlatformPairingQrScanner().scan(), 'bounded-raw-qr');
  });

  test(
    'maps native cancellation to no scan and refuses failure or oversize',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async => null);
      expect(await const PlatformPairingQrScanner().scan(), isNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(code: 'scanner_unavailable');
          });
      await expectLater(
        const PlatformPairingQrScanner().scan(),
        throwsA(isA<StateError>()),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (MethodCall call) async => 'x' * 4097,
          );
      await expectLater(
        const PlatformPairingQrScanner().scan(),
        throwsA(isA<StateError>()),
      );
    },
  );
}
