import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android directional-key vault uses narrow Keystore atomic-write contract',
      () {
    final String vault = File(
      'android/app/src/main/kotlin/com/example/opencongopay/pairing/PairingDirectionalKeyVault.kt',
    ).readAsStringSync();
    final String activity = File(
      'android/app/src/main/kotlin/com/example/opencongopay/MainActivity.kt',
    ).readAsStringSync();

    expect(vault, contains('context.noBackupFilesDir'));
    expect(vault, contains('AtomicFile(recordFile)'));
    expect(vault, contains('"AndroidKeyStore"'));
    expect(vault, contains('KeyProperties.KEY_ALGORITHM_AES'));
    expect(vault, contains('"AES/GCM/NoPadding"'));
    expect(vault, contains('updateAAD(AAD)'));
    expect(vault, contains('ENVELOPE_VERSION'));
    expect(vault, contains('KEY_BYTES = 32'));
    expect(vault, isNot(contains('fun read(')));
    expect(activity, contains('openpaycongo/pairing_directional_keys'));
    expect(activity, contains('arguments.keys != setOf("send_key", "receive_key")'));
    expect(activity, contains('sendKey.size != 32 || receiveKey.size != 32'));
  });
}
