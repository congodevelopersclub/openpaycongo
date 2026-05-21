import 'dart:developer' as dev;

import 'package:another_telephony/telephony.dart';
import 'package:opencongopay/models/paymentdetail.dart';

class SmsParser {
  final Telephony _telephony = Telephony.instance;

  Future<void> initialize() async {
    final bool? isSMSAllowed = await _telephony.requestSmsPermissions;

    if (isSMSAllowed != null && isSMSAllowed) {
      _log('SMS permissions granted');
      _telephony.listenIncomingSms(
        onNewMessage: _backgroundMessageHandler,
        onBackgroundMessage: _backgroundMessageHandler,
      );

      _log('SMS listener initialized');
      return;
    }
  }
}

void _log(String log) {
  dev.log(log, name: 'SMS Listener');
}

Future<void> _backgroundMessageHandler(SmsMessage message) async {
  processOrangeMessageWithRegex(message);
}

PaymentDetail processOrangeMessageWithRegex(SmsMessage message) {
  final regex = RegExp(
    r'Vous avez recu (\d+(?:\.\d+)?) (\S+) de (\S+) (\d+)\. Nouveau solde: (\d+(?:\.\d+)?) (\S+). Ref: (\S+)',
  );

  final match = regex.firstMatch(message.body ?? '');

  if (match == null) {
    _log('Invalid SMS message format');
    throw OrangeRegexMissMatchException(
      'failed to match regex for an orange message',
    );
  }

  final amount = match.group(1);
  final currency = match.group(2);
  final name = match.group(3);
  final number = match.group(4);
  final balance = match.group(5);
  final reference = match.group(7);

  _log(
    'Data extracted successfully. Name: $name, Number: $number, Amount: $amount, Balance: $balance, Reference: $reference',
  );

  return PaymentDetail(
    name: name ?? '',
    sender: number ?? '',
    amount: amount ?? '',
    currency: currency ?? '',
    balance: balance ?? '',
    reference: reference ?? '',
  );
}

class OrangeRegexMissMatchException implements SMSRegexMissMatchException {
  @override
  final String message;

  OrangeRegexMissMatchException(this.message);
}

class SMSRegexMissMatchException implements Exception {
  final String message;

  SMSRegexMissMatchException(this.message);
}
