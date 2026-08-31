import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android pairing pin storage is Keystore-backed and excluded from backup', () {
    final String manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final String vault = File(
      'android/app/src/main/kotlin/com/example/opencongopay/pairing/PairingQrTrustVault.kt',
    ).readAsStringSync();
    final String legacyBackup = File('android/app/src/main/res/xml/backup_rules.xml')
        .readAsStringSync();
    final String extractionRules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(vault, contains('context.noBackupFilesDir'));
    expect(vault, contains('"AndroidKeyStore"'));
    expect(vault, contains('KeyProperties.KEY_ALGORITHM_AES'));
    expect(legacyBackup, contains('<exclude domain="root" path="." />'));
    expect(extractionRules, contains('<device-transfer>'));
    expect(extractionRules, contains('<exclude domain="root" path="." />'));
  });
}
