import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/platform_pairing_qr_trust_store.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_bloc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('openpaycongo/pairing_qr_trust');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('maps native lookup and idempotent pinned writes without exposing pin', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'lookup' => 'matching',
            'persistVerifiedFingerprint' => 'already_stored',
            _ => throw MissingPluginException(),
          };
        });
    const PlatformPairingQrTrustStore store = PlatformPairingQrTrustStore();

    expect(
      await store.lookup('Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0'),
      isA<PairingQrMatchingPin>(),
    );
    expect(
      await store.persistVerifiedFingerprint(
        'Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0',
      ),
      isA<PairingQrPinAlreadyStored>(),
    );
    expect(calls.map((MethodCall call) => call.method), <String>[
      'lookup',
      'persistVerifiedFingerprint',
    ]);
  });

  test('fails closed for unknown native outcomes and secure storage errors', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'lookup') return 'unknown';
          throw PlatformException(code: 'secure_storage_failure');
        });
    const PlatformPairingQrTrustStore store = PlatformPairingQrTrustStore();

    expect(
      store.lookup('Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      store.persistVerifiedFingerprint(
        'Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0',
      ),
      throwsA(isA<StateError>()),
    );
  });
}
