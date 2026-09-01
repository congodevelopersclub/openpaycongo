import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/pairing_activation_retrieval.dart';
import 'package:opencongopay/features/pairing/infrastructure/platform_pairing_activation_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('openpaycongo/pairing_activation');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('retrieves opaque envelope then returns only activated', () async {
    final _Transport transport = _Transport();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'consume');
          expect((call.arguments as Map<Object?, Object?>).keys,
              unorderedEquals(<String>['intent_id', 'nonce', 'ciphertext']));
          return 'activated';
        });

    final PairingActivationConsumeResult outcome = await PairingActivationConsumer(
      transport: transport,
      vault: const PlatformPairingActivationVault(),
    ).retrieveAndConsume(
      completionEndpoint: Uri.parse('https://pairing.example.test/v1/pairing/complete'),
      intentId: Uint8List(16),
    );

    expect(outcome, PairingActivationConsumeResult.activated);
    expect(transport.endpoint.toString(), 'https://pairing.example.test/v1/pairing/complete');
  });

  test('retrieval failure returns recovery without platform call', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls += 1;
          return 'activated';
        });

    final PairingActivationConsumeResult outcome = await PairingActivationConsumer(
      transport: const _FailingTransport(),
      vault: const PlatformPairingActivationVault(),
    ).retrieveAndConsume(
      completionEndpoint: Uri.parse('https://pairing.example.test/v1/pairing/complete'),
      intentId: Uint8List(16),
    );

    expect(outcome, PairingActivationConsumeResult.recoveryRequired);
    expect(calls, 0);
  });
}

final class _Transport implements PairingActivationRetrievalTransport {
  late Uri endpoint;
  late Uint8List intent;

  @override
  Future<PairingActivationEnvelope> retrieve(Uri endpoint, Uint8List intentId) async {
    this.endpoint = endpoint;
    intent = Uint8List.fromList(intentId);
    return PairingActivationEnvelope(
      nonce: Uint8List(24),
      ciphertext: Uint8List.fromList(<int>[1, 2, 3]),
    );
  }
}

final class _FailingTransport implements PairingActivationRetrievalTransport {
  const _FailingTransport();

  @override
  Future<PairingActivationEnvelope> retrieve(Uri endpoint, Uint8List intentId) =>
      throw const PairingActivationRetrievalFailure();
}
