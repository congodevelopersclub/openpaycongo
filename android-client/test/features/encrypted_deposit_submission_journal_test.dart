import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/data/encrypted_deposit_submission_journal.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_runtime.dart';
import 'package:opencongopay/features/payment_outbox/data/sqlite_payment_outbox_repository.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _MemoryCipher implements PaymentOutboxCipher {
  final Map<String, String> _cleartexts = <String, String>{};

  @override
  Future<String> decrypt({required String identity, required String ciphertext}) async =>
      _cleartexts['$identity/$ciphertext']!;

  @override
  Future<String> encrypt({required String identity, required String cleartext}) async {
    final String ciphertext = sha256.convert(utf8.encode('$identity/$cleartext')).toString();
    _cleartexts['$identity/$ciphertext'] = cleartext;
    return ciphertext;
  }
}

final class _Location implements PaymentOutboxStorageLocation {
  const _Location(this.path);

  final String path;

  @override
  Future<String> directory() async => path;
}

final class _ReplayTransport implements AuthenticatedDepositTransport {
  final List<ProviderDeposit> submissions = <ProviderDeposit>[];

  @override
  Future<DepositSubmissionResult> submit(ProviderDeposit deposit) async {
    submissions.add(deposit);
    return const DepositSubmissionResult.replayed();
  }
}

const ProviderDeposit _deposit = ProviderDeposit(
  customerLookupIdentifier: 'customer-sensitive-001',
  providerReference: 'reference-sensitive-001',
  amountMinor: 12500,
  currency: 'CDF',
  providerOccurredAt: '2026-09-01T01:00:00Z',
  customerPhone: '+243000000000',
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('staged deposit survives reopen while SQLite contains ciphertext only', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-deposit-journal-');
    final _MemoryCipher cipher = _MemoryCipher();
    final String databasePath = join(directory.path, 'opencongopay-deposit-journal.db');
    try {
      final EncryptedDepositSubmissionJournal first =
          await EncryptedDepositSubmissionJournal.open(cipher: cipher, location: _Location(directory.path));
      await first.stage(_deposit);
      await first.close();

      final String raw = String.fromCharCodes(await File(databasePath).readAsBytes());
      expect(raw, isNot(contains(_deposit.customerLookupIdentifier)));
      expect(raw, isNot(contains(_deposit.providerReference)));
      expect(raw, isNot(contains(_deposit.customerPhone)));
      expect(raw, isNot(contains(_deposit.amountMinor.toString())));

      final EncryptedDepositSubmissionJournal reopened =
          await EncryptedDepositSubmissionJournal.open(cipher: cipher, location: _Location(directory.path));
      final List<ProviderDeposit> pending = await reopened.loadPending();
      expect(pending, hasLength(1));
      _expectSameDeposit(pending.single, _deposit);
      await reopened.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('conflict is atomically quarantined and never returned for automatic replay', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-deposit-conflict-');
    final _MemoryCipher cipher = _MemoryCipher();
    try {
      final EncryptedDepositSubmissionJournal journal =
          await EncryptedDepositSubmissionJournal.open(cipher: cipher, location: _Location(directory.path));
      await journal.stage(_deposit);
      await journal.markConflict(_deposit);
      expect(await journal.loadPending(), isEmpty);
      await expectLater(journal.stage(_deposit), throwsA(isA<DepositJournalRecoveryRequiredException>()));
      await journal.close();

      final EncryptedDepositSubmissionJournal restarted =
          await EncryptedDepositSubmissionJournal.open(cipher: cipher, location: _Location(directory.path));
      expect(await restarted.loadPending(), isEmpty);
      await restarted.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('recorded removal deletes only matching durable pending ingress', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-deposit-remove-');
    try {
      final EncryptedDepositSubmissionJournal journal = await EncryptedDepositSubmissionJournal.open(
        cipher: _MemoryCipher(),
        location: _Location(directory.path),
      );
      await journal.stage(_deposit);
      await journal.remove(_deposit);
      expect(await journal.loadPending(), isEmpty);
      await journal.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('runtime creation replays durable pending ingress before exposing its bloc', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-deposit-runtime-');
    final _MemoryCipher cipher = _MemoryCipher();
    try {
      final EncryptedDepositSubmissionJournal journal =
          await EncryptedDepositSubmissionJournal.open(cipher: cipher, location: _Location(directory.path));
      await journal.stage(_deposit);
      await journal.close();

      final _ReplayTransport replay = _ReplayTransport();
      final DepositSubmissionRuntime runtime = await DepositSubmissionRuntime.create(
        transport: replay,
        cipher: cipher,
        location: _Location(directory.path),
      );
      expect(replay.submissions, hasLength(1));
      _expectSameDeposit(replay.submissions.single, _deposit);
      await runtime.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

void _expectSameDeposit(ProviderDeposit actual, ProviderDeposit expected) {
  expect(actual.customerLookupIdentifier, expected.customerLookupIdentifier);
  expect(actual.providerReference, expected.providerReference);
  expect(actual.amountMinor, expected.amountMinor);
  expect(actual.currency, expected.currency);
  expect(actual.providerOccurredAt, expected.providerOccurredAt);
  expect(actual.customerPhone, expected.customerPhone);
}
