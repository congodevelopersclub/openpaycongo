import 'package:opencongopay/features/deposit_sync/data/encrypted_deposit_submission_journal.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';
import 'package:opencongopay/features/payment_outbox/data/sqlite_payment_outbox_repository.dart';

/// Public composition seam for a paired-installation owner. Authentication
/// remains injected; this runtime owns only encrypted deposit persistence.
final class DepositSubmissionRuntime {
  DepositSubmissionRuntime._(this.bloc, this._journal);

  final DepositSubmissionBloc bloc;
  final EncryptedDepositSubmissionJournal _journal;

  static Future<DepositSubmissionRuntime> create({
    required AuthenticatedDepositTransport transport,
    PaymentOutboxCipher? cipher,
    PaymentOutboxStorageLocation? location,
  }) async {
    final EncryptedDepositSubmissionJournal journal =
        await EncryptedDepositSubmissionJournal.open(cipher: cipher, location: location);
    final DepositSubmissionBloc bloc = DepositSubmissionBloc(
      transport: transport,
      journal: journal,
    );
    await bloc.start();
    return DepositSubmissionRuntime._(bloc, journal);
  }

  Future<void> close() async {
    await bloc.close();
    await _journal.close();
  }
}
