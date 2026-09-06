import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/infrastructure/pairing_activation_acknowledgement.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_protocol_bloc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('openpaycongo/pairing_activation');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('native acknowledgement state is redacted', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'acknowledgementState');
          expect(call.arguments, isNull);
          return 'pending';
        });

    final PairingActivationAcknowledgementRecovery state =
        await const PlatformPairingActivationAcknowledgementVault().restore();

    expect(state, PairingActivationAcknowledgementRecovery.pending);
    expect(state.toString(), isNot(contains('key')));
  });

  test('Dart acknowledgement boundary cannot carry pairing credentials or keys', () {
    final String source = File(
      'lib/features/pairing/infrastructure/pairing_activation_acknowledgement.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('bearer')));
    expect(source, isNot(contains('pairing_secret')));
    expect(source, isNot(contains('send_key')));
    expect(source, isNot(contains('receive_key')));
  });

  test('native bridge returns only routing-safe acknowledgement envelope and outcome', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return switch (call.method) {
            'sealAcknowledgement' => <String, Object>{
              'version': 1,
              'server_base_url': 'https://pairing.example.test',
              'installation_id': '123e4567-e89b-12d3-a456-426614174000',
              'counter': '7',
              'nonce': 'outer-request-nonce',
              'ciphertext': 'outer-request-ciphertext',
            },
            'openAcknowledgement' => 'acknowledged',
            _ => throw PlatformException(code: 'unexpected'),
          };
        });
    const PlatformPairingActivationAcknowledgementVault vault =
        PlatformPairingActivationAcknowledgementVault();

    final PairingActivationAcknowledgementEnvelope envelope = await vault.seal();
    final bool acknowledged = await vault.open(
      request: envelope,
      status: 201,
      nonce: 'outer-response-nonce',
      ciphertext: 'outer-response-ciphertext',
    );

    expect(acknowledged, isTrue);
    expect(calls.map((MethodCall call) => call.method), <String>[
      'sealAcknowledgement',
      'openAcknowledgement',
    ]);
    expect((calls.last.arguments as Map<Object?, Object?>).keys, <String>[
      'installation_id',
      'counter',
      'status',
      'nonce',
      'ciphertext',
    ]);
  });

  test('one deadline bounds acknowledgement exchange and leaves retry recoverable', () async {
    final _DeferredAcknowledgementPost post = _DeferredAcknowledgementPost();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'sealAcknowledgement');
          return _envelope();
        });
    final PairingV2ActivationAcknowledgementPort port =
        PairingV2ActivationAcknowledgementPort(
      vault: const PlatformPairingActivationAcknowledgementVault(),
      timeout: const Duration(milliseconds: 10),
      post: post.call,
    );

    final PairingActivationAcknowledgementOutcome outcome = await port.acknowledge();

    expect(outcome, PairingActivationAcknowledgementOutcome.retryable);
    expect(post.calls, 1);
  });

  test('retry seals a fresh envelope and opens only authenticated acknowledgement', () async {
    var seals = 0;
    var opens = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          return switch (call.method) {
            'sealAcknowledgement' => _envelope(counter: '${++seals}'),
            'openAcknowledgement' => opens++ == 0 ? 'unavailable' : 'acknowledged',
            _ => throw PlatformException(code: 'unexpected'),
          };
        });
    final PairingV2ActivationAcknowledgementPort port =
        PairingV2ActivationAcknowledgementPort(
      vault: const PlatformPairingActivationAcknowledgementVault(),
      post: (_, PairingActivationAcknowledgementEnvelope envelope) async =>
          PairingActivationAcknowledgementHttpResponse(
            status: 201,
            nonce: 'response-nonce-${envelope.counter}',
            ciphertext: 'response-ciphertext-${envelope.counter}',
          ),
    );

    final PairingActivationAcknowledgementOutcome first = await port.acknowledge();
    final PairingActivationAcknowledgementOutcome second = await port.acknowledge();

    expect(first, PairingActivationAcknowledgementOutcome.retryable);
    expect(second, PairingActivationAcknowledgementOutcome.acknowledged);
    expect(seals, 2);
    expect(opens, 2);
  });
}

Map<String, Object> _envelope({String counter = '7'}) => <String, Object>{
  'version': 1,
  'server_base_url': 'https://pairing.example.test',
  'installation_id': '123e4567-e89b-12d3-a456-426614174000',
  'counter': counter,
  'nonce': 'outer-request-nonce',
  'ciphertext': 'outer-request-ciphertext',
};

final class _DeferredAcknowledgementPost {
  var calls = 0;

  Future<PairingActivationAcknowledgementHttpResponse?> call(
    HttpClient client,
    PairingActivationAcknowledgementEnvelope envelope,
  ) {
    calls += 1;
    return Completer<PairingActivationAcknowledgementHttpResponse?>().future;
  }
}
