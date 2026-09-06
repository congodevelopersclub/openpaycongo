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
}
