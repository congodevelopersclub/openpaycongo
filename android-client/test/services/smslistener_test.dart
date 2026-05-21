import 'package:another_telephony/telephony.dart';
import 'package:opencongopay/models/paymentdetail.dart';
import 'package:opencongopay/services/SmsListener/smsparser.dart';
import 'package:test/test.dart';

void main() {
  test('Process Message with Orange Regex Return the correct values', () {
    final details = [
      {
        "name": "Paul",
        "sender": "0994783214",
        "amount": "6870.00",
        "balance": "100000",
        "currency": "CDF",
        "reference": "PP221226.1651.B30320",
      },
      {
        "name": "Mbayo",
        "sender": "0814783214",
        "amount": "87.00",
        "balance": "50000",
        "currency": "USD",
        "reference": "PP221226.1651.B58320",
      },
      {
        "name": "Cibadia",
        "sender": "0924783214",
        "amount": "685.02",
        "balance": "350000",
        "currency": "CDF",
        "reference": "PP221226.6981.B30320",
      },
    ];

    for (final detail in details) {
      final SmsMessage orangeMessage = SmsMessage.fromMap({
        "_id": "12",
        "originating_address": "0000000000",
        "address": "0000000000",
        "message_body":
            'Vous avez recu ${detail['amount']} ${detail['currency']} de ${detail['name']} ${detail['sender']}. Nouveau solde: ${detail['balance']} ${detail['currency']}. Ref: ${detail['reference']}',
        "timestamp": "1595056125663",
        "service_center": "0000000000",
        "thread_id": "6",
        "status": "STATUS_COMPLETE",
      }, INCOMING_SMS_COLUMNS);

      PaymentDetail payment = processOrangeMessageWithRegex(orangeMessage);

      expect(payment.id, null);
      expect(payment.name, detail['name']);
      expect(payment.sender, detail['sender']);
      expect(payment.amount, detail['amount']);
      expect(payment.currency, detail['currency']);
      expect(payment.balance, detail['balance']);
      expect(payment.reference, detail['reference']);
    }
  });
}
