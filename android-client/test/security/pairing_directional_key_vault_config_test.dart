import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android pairing state uses a native-only Keystore atomic-write contract',
      () {
    final String vault = File(
      'android/app/src/main/kotlin/com/example/opencongopay/pairing/PairingDirectionalKeyVault.kt',
    ).readAsStringSync();
    final String activity = File(
      'android/app/src/main/kotlin/com/example/opencongopay/MainActivity.kt',
    ).readAsStringSync();
    final String completion = File(
      'android/app/src/main/kotlin/com/example/opencongopay/pairing/PairingV2NativeCompletion.kt',
    ).readAsStringSync();
    final String protocol = File(
      'lib/features/pairing/presentation/pairing_protocol_bloc.dart',
    ).readAsStringSync();
    final String bridge = File(
      'lib/features/pairing/infrastructure/platform_pairing_v2_crypto.dart',
    ).readAsStringSync();
    final String onDestroy = _kotlinFunctionBody(activity, 'override fun onDestroy()');
    final String cancel = _kotlinFunctionBody(completion, 'fun cancel()');
    final String releaseForActivityDestroy = _kotlinFunctionBody(
      completion,
      'fun releaseForActivityDestroy()',
    );

    expect(vault, contains('context.noBackupFilesDir'));
    expect(vault, contains('AtomicFile(recordFile)'));
    expect(vault, contains('"AndroidKeyStore"'));
    expect(vault, contains('KeyProperties.KEY_ALGORITHM_AES'));
    expect(vault, contains('"AES/GCM/NoPadding"'));
    expect(vault, contains('updateAAD(AAD)'));
    expect(vault, contains('ENVELOPE_VERSION'));
    expect(vault, contains('KEY_BYTES = 32'));
    expect(vault, contains('INSTALLATION_ID_BYTES = 16'));
    expect(vault, contains('PairingOutboundMaterial'));
    expect(vault, contains('credential.bearerToken'));
    expect(vault, contains('STORAGE_LOCK'));
    expect(vault, contains('LEGACY_RECORD_FILE'));
    expect(vault, contains('LegacyPairingActivationCredentialVault'));
    expect(vault, isNot(contains('fun read(')));
    expect(activity, contains('openpaycongo/pairing_completion'));
    expect(activity, isNot(contains('openpaycongo/pairing_directional_keys')));
    expect(onDestroy, contains('pairingV2Completion.releaseForActivityDestroy()'));
    expect(onDestroy, isNot(contains('pairingV2Completion.cancel()')));
    expect(activity, contains('"pairing_secret"'));
    expect(activity, contains('pairingSecret.fill(0)'));
    expect(completion, contains('fun consumeActivation'));
    expect(completion, contains('fun releaseForActivityDestroy()'));
    expect(completion, contains('fun cancel()'));
    expect(releaseForActivityDestroy, isNot(contains('recoveryVault.clear()')));
    expect(releaseForActivityDestroy, contains('current?.dispose()'));
    expect(cancel, contains('recoveryVault.clear()'));
    expect(completion, contains('PairingDirectionalKeyVault(context).save('));
    expect(completion, contains('                credential,'));
    expect(completion, contains('current.sendKey'));
    expect(completion, contains('current.receiveKey'));
    expect(completion, isNot(contains('PairingActivationCredentialVault(context).save')));
    expect(protocol, contains('_activationActive ||'));
    expect(completion, isNot(contains('"send_key"')));
    expect(completion, isNot(contains('"receive_key"')));
    expect(bridge, isNot(contains('send_key')));
    expect(bridge, isNot(contains('receive_key')));
  });
}

String _kotlinFunctionBody(String source, String signature) {
  final int signatureStart = source.indexOf(signature);
  expect(signatureStart, isNot(-1), reason: 'missing $signature');
  final int bodyStart = source.indexOf('{', signatureStart);
  expect(bodyStart, isNot(-1), reason: 'missing body for $signature');
  var depth = 0;
  for (var index = bodyStart; index < source.length; index += 1) {
    final String character = source[index];
    if (character == '{') depth += 1;
    if (character == '}') depth -= 1;
    if (depth == 0) return source.substring(bodyStart + 1, index);
  }
  fail('unterminated body for $signature');
}
