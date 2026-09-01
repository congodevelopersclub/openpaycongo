import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';
import 'package:opencongopay/features/payment_outbox/data/sqlite_payment_outbox_repository.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Key loss, corrupted ciphertext, or an incomplete durable mutation. Callers
/// must reconcile storage; its message intentionally carries no ingress data.
final class DepositJournalRecoveryRequiredException implements Exception {
  const DepositJournalRecoveryRequiredException();
}

final class _JournalRecord {
  const _JournalRecord({
    required this.recordId,
    required this.ciphertext,
    required this.cipherVersion,
  });

  final String recordId;
  final String ciphertext;
  final int cipherVersion;

  Map<String, Object> get databaseValues => <String, Object>{
    'record_id': recordId,
    'ciphertext': ciphertext,
    'cipher_version': cipherVersion,
  };
}

enum _JournalState { pending, conflict }

final class _JournalEntry {
  const _JournalEntry({
    required this.deposit,
    required this.state,
    required this.createdAt,
  });

  final ProviderDeposit deposit;
  final _JournalState state;
  final DateTime createdAt;
}

/// Ciphertext-only durable ingress journal. Native [PaymentOutboxCipher] binds
/// every record to a random opaque identity and stores its database under the
/// Android no-backup directory.
final class EncryptedDepositSubmissionJournal implements DepositSubmissionJournal {
  EncryptedDepositSubmissionJournal._(this._database, this._cipher);

  static const int _cipherVersion = 1;
  static const String _databaseName = 'opencongopay-deposit-journal.db';

  final Database _database;
  final PaymentOutboxCipher _cipher;

  static Future<EncryptedDepositSubmissionJournal> open({
    PaymentOutboxCipher? cipher,
    PaymentOutboxStorageLocation? location,
  }) async {
    final PlatformPaymentOutboxCipher platform = const PlatformPaymentOutboxCipher();
    try {
      final Database database = await openDatabase(
        join(await (location ?? platform).directory(), _databaseName),
        version: 1,
        onCreate: (Database db, int _) => db.execute(
          'CREATE TABLE deposit_submission_journal (record_id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL, cipher_version INTEGER NOT NULL)',
        ),
        onUpgrade: (_, _, _) => throw const DepositJournalRecoveryRequiredException(),
      );
      return EncryptedDepositSubmissionJournal._(database, cipher ?? platform);
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on PlatformException {
      throw const DepositJournalRecoveryRequiredException();
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  Future<void> close() => _database.close();

  @override
  Future<void> stage(ProviderDeposit deposit) async {
    try {
      final List<_StoredEntry> existing = await _entries();
      for (final _StoredEntry entry in existing) {
        if (!_sameDeposit(entry.entry.deposit, deposit)) continue;
        if (entry.entry.state == _JournalState.conflict) {
          throw const DepositJournalRecoveryRequiredException();
        }
        return;
      }
      final String recordId = _randomRecordId();
      final _JournalRecord record = await _seal(
        _JournalEntry(
          deposit: deposit,
          state: _JournalState.pending,
          createdAt: DateTime.now().toUtc(),
        ),
        recordId: recordId,
      );
      await _database.insert(
        'deposit_submission_journal',
        record.databaseValues,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  @override
  Future<List<ProviderDeposit>> loadPending() async {
    try {
      final List<_StoredEntry> entries = await _entries();
      return (entries
            .where((_StoredEntry entry) => entry.entry.state == _JournalState.pending)
            .toList()
          ..sort((_StoredEntry left, _StoredEntry right) {
            final int created = left.entry.createdAt.compareTo(right.entry.createdAt);
            return created != 0 ? created : left.record.recordId.compareTo(right.record.recordId);
          }))
        .map((_StoredEntry entry) => entry.entry.deposit)
        .toList(growable: false);
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  @override
  Future<void> remove(ProviderDeposit deposit) => _delete(deposit, requirePending: true);

  @override
  Future<void> markConflict(ProviderDeposit deposit) async {
    try {
      final _StoredEntry stored = await _find(deposit, requirePending: true);
      final _JournalRecord replacement = await _seal(
        _JournalEntry(
          deposit: stored.entry.deposit,
          state: _JournalState.conflict,
          createdAt: stored.entry.createdAt,
        ),
        recordId: stored.record.recordId,
      );
      final int changed = await _database.update(
        'deposit_submission_journal',
        replacement.databaseValues,
        where: 'record_id = ? AND ciphertext = ?',
        whereArgs: <Object>[stored.record.recordId, stored.record.ciphertext],
      );
      if (changed != 1) throw const DepositJournalRecoveryRequiredException();
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  Future<void> _delete(ProviderDeposit deposit, {required bool requirePending}) async {
    try {
      final _StoredEntry stored = await _find(deposit, requirePending: requirePending);
      if (await _database.delete(
            'deposit_submission_journal',
            where: 'record_id = ? AND ciphertext = ?',
            whereArgs: <Object>[stored.record.recordId, stored.record.ciphertext],
          ) !=
          1) {
        throw const DepositJournalRecoveryRequiredException();
      }
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  Future<_StoredEntry> _find(ProviderDeposit deposit, {required bool requirePending}) async {
    for (final _StoredEntry entry in await _entries()) {
      if (!_sameDeposit(entry.entry.deposit, deposit)) continue;
      if (!requirePending || entry.entry.state == _JournalState.pending) return entry;
    }
    throw const DepositJournalRecoveryRequiredException();
  }

  Future<List<_StoredEntry>> _entries() async {
    final List<Map<String, Object?>> rows = await _database.query('deposit_submission_journal');
    return Future.wait(rows.map((Map<String, Object?> row) async {
      final _JournalRecord record = _recordFrom(row);
      return _StoredEntry(record: record, entry: await _open(record));
    }));
  }

  Future<_JournalRecord> _seal(_JournalEntry entry, {required String recordId}) async {
    _requireRecordId(recordId);
    try {
      return _JournalRecord(
        recordId: recordId,
        ciphertext: await _cipher.encrypt(
          identity: recordId,
          cleartext: jsonEncode(<String, Object?>{
            'schema': _cipherVersion,
            'state': entry.state.name,
            'created_at': entry.createdAt.toUtc().toIso8601String(),
            'customer_lookup_identifier': entry.deposit.customerLookupIdentifier,
            'provider_reference': entry.deposit.providerReference,
            'amount_minor': entry.deposit.amountMinor,
            'currency': entry.deposit.currency,
            'provider_occurred_at': entry.deposit.providerOccurredAt,
            'sender_identifier': entry.deposit.senderIdentifier,
            'receiver_identifier': entry.deposit.receiverIdentifier,
            'customer_name': entry.deposit.customerName,
            'customer_address': entry.deposit.customerAddress,
            'customer_phone': entry.deposit.customerPhone,
            'customer_email': entry.deposit.customerEmail,
          }),
        ),
        cipherVersion: _cipherVersion,
      );
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  Future<_JournalEntry> _open(_JournalRecord record) async {
    if (record.cipherVersion != _cipherVersion) {
      throw const DepositJournalRecoveryRequiredException();
    }
    try {
      final Object? decoded = jsonDecode(await _cipher.decrypt(
        identity: record.recordId,
        ciphertext: record.ciphertext,
      ));
      if (decoded is! Map<String, dynamic> || decoded['schema'] != _cipherVersion) {
        throw const FormatException();
      }
      return _JournalEntry(
        deposit: ProviderDeposit(
          customerLookupIdentifier: _requiredString(decoded, 'customer_lookup_identifier'),
          providerReference: _requiredString(decoded, 'provider_reference'),
          amountMinor: _nonNegativeInt(decoded, 'amount_minor'),
          currency: _requiredString(decoded, 'currency'),
          providerOccurredAt: _requiredString(decoded, 'provider_occurred_at'),
          senderIdentifier: _optionalString(decoded, 'sender_identifier'),
          receiverIdentifier: _optionalString(decoded, 'receiver_identifier'),
          customerName: _optionalString(decoded, 'customer_name'),
          customerAddress: _optionalString(decoded, 'customer_address'),
          customerPhone: _optionalString(decoded, 'customer_phone'),
          customerEmail: _optionalString(decoded, 'customer_email'),
        ),
        state: _JournalState.values.byName(_requiredString(decoded, 'state')),
        createdAt: DateTime.parse(_requiredString(decoded, 'created_at')).toUtc(),
      );
    } on DepositJournalRecoveryRequiredException {
      rethrow;
    } on Object {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  static _JournalRecord _recordFrom(Map<String, Object?> row) {
    final Object? recordId = row['record_id'];
    final Object? ciphertext = row['ciphertext'];
    final Object? cipherVersion = row['cipher_version'];
    if (recordId is! String || ciphertext is! String || cipherVersion is! int) {
      throw const DepositJournalRecoveryRequiredException();
    }
    _requireRecordId(recordId);
    return _JournalRecord(recordId: recordId, ciphertext: ciphertext, cipherVersion: cipherVersion);
  }

  static String _requiredString(Map<String, dynamic> value, String key) {
    final Object? result = value[key];
    if (result is! String || result.isEmpty) throw const FormatException();
    return result;
  }

  static String? _optionalString(Map<String, dynamic> value, String key) {
    final Object? result = value[key];
    if (result != null && result is! String) throw const FormatException();
    return result as String?;
  }

  static int _nonNegativeInt(Map<String, dynamic> value, String key) {
    final Object? result = value[key];
    if (result is! int || result < 0) throw const FormatException();
    return result;
  }

  static void _requireRecordId(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const DepositJournalRecoveryRequiredException();
    }
  }

  static String _randomRecordId() {
    const String hex = '0123456789abcdef';
    final Random random = Random.secure();
    return List<String>.generate(64, (_) => hex[random.nextInt(hex.length)]).join();
  }

  static bool _sameDeposit(ProviderDeposit left, ProviderDeposit right) =>
      left.customerLookupIdentifier == right.customerLookupIdentifier &&
      left.providerReference == right.providerReference &&
      left.amountMinor == right.amountMinor &&
      left.currency == right.currency &&
      left.providerOccurredAt == right.providerOccurredAt &&
      left.senderIdentifier == right.senderIdentifier &&
      left.receiverIdentifier == right.receiverIdentifier &&
      left.customerName == right.customerName &&
      left.customerAddress == right.customerAddress &&
      left.customerPhone == right.customerPhone &&
      left.customerEmail == right.customerEmail;
}

final class _StoredEntry {
  const _StoredEntry({required this.record, required this.entry});

  final _JournalRecord record;
  final _JournalEntry entry;
}
