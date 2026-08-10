import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual-first prototype declares no restricted SMS capture surface', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, isNot(contains('android.permission.RECEIVE_SMS')));
    expect(manifest, isNot(contains('android.permission.READ_SMS')));
    expect(manifest, isNot(contains('IncomingSmsReceiver')));
    expect(
      manifest,
      isNot(contains('android.provider.Telephony.SMS_RECEIVED')),
    );
  });

  test('manual-first prototype ships no legacy permission requester', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('another_telephony:')));
    expect(
      File('lib/services/SmsListener/smsparser.dart').existsSync(),
      isFalse,
    );
  });
}
