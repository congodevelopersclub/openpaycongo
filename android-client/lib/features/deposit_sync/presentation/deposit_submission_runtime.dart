import 'package:opencongopay/features/deposit_sync/data/mobile_deposit_http_transport.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_envelope_http_transport.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_envelope_sealer.dart';
import 'package:opencongopay/features/deposit_sync/data/encrypted_deposit_submission_journal.dart';
import 'package:opencongopay/features/deposit_sync/infrastructure/platform_mobile_envelope_vault.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';
import 'package:opencongopay/features/payment_outbox/data/sqlite_payment_outbox_repository.dart';

/// Public composition seam for a paired installation. It owns encrypted deposit
/// persistence; its paired transport keeps envelope keys and plaintext outside
/// the BLoC and Dart network boundary.
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

  /// Production pairing composition. The native vault alone owns directional
  /// keys and the pinned server authority; Dart receives only ciphertext.
  static Future<DepositSubmissionRuntime> createPairedMobileEnvelope({
    MobileEnvelopeSealer? vault,
    MobileDepositHttpPort? http,
    PaymentOutboxCipher? cipher,
    PaymentOutboxStorageLocation? location,
  }) => create(
    transport: MobileEnvelopeHttpTransport(
      vault: vault ?? const PlatformMobileEnvelopeVault(),
      http: http ?? DartMobileDepositHttpPort(),
    ),
    cipher: cipher,
    location: location,
  );

  Future<void> close() async {
    await bloc.close();
    await _journal.close();
  }
}
