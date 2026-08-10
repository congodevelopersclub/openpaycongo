import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('financial SMS capture surface is minimal and background capable', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android.permission.RECEIVE_SMS'));
    expect(manifest, isNot(contains('android.permission.READ_SMS')));
    expect(manifest, isNot(contains('android.permission.RECEIVE_MMS')));
    expect(manifest, isNot(contains('android.permission.RECEIVE_WAP_PUSH')));
    expect(manifest, isNot(contains('android.permission.SEND_SMS')));
    expect(manifest, contains('.sms.SmsDeliverReceiver'));
    expect(manifest, contains('android.permission.BROADCAST_SMS'));
    expect(manifest, contains('android.provider.Telephony.SMS_RECEIVED'));
    expect(manifest, isNot(contains('android.provider.Telephony.SMS_DELIVER')));
  });

  test('financial SMS permission uses platform APIs, not legacy plugins', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('another_telephony:')));
    expect(
      File('lib/services/SmsListener/smsparser.dart').existsSync(),
      isFalse,
    );
  });
}
