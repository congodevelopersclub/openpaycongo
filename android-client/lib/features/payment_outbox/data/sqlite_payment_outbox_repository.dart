import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

abstract interface class PaymentOutboxCipher {
  Future<String> encrypt({required String identity, required String cleartext});
  Future<String> decrypt({required String identity, required String ciphertext});
}

abstract interface class PaymentOutboxStorageLocation {
  Future<String> directory();
}

final class OutboxRecoveryRequiredException implements Exception {
  const OutboxRecoveryRequiredException();
}

final class PlatformPaymentOutboxCipher
    implements PaymentOutboxCipher, PaymentOutboxStorageLocation {
  const PlatformPaymentOutboxCipher([
    this._channel = const MethodChannel('openpaycongo/payment_outbox'),
  ]);

  final MethodChannel _channel;

  @override
  Future<String> directory() => _invoke('storageDirectory');

  @override
  Future<String> encrypt({required String identity, required String cleartext}) =>
      _invoke('encrypt', identity: identity, value: cleartext);

  @override
  Future<String> decrypt({required String identity, required String ciphertext}) =>
      _invoke('decrypt', identity: identity, value: ciphertext);

  Future<String> _invoke(String method, {String? identity, String? value}) async {
    try {
      return (await _channel.invokeMethod<String>(method, identity == null
          ? null
          : <String, String>{'identity': identity, 'value': value!}))!;
    } on PlatformException {
      throw const OutboxRecoveryRequiredException();
    }
  }
}

final class OutboxCiphertextRecord {
  const OutboxCiphertextRecord({
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

  OutboxCiphertextRecord copyWith({
    String? recordId,
    String? ciphertext,
    int? cipherVersion,
  }) => OutboxCiphertextRecord(
    recordId: recordId ?? this.recordId,
    ciphertext: ciphertext ?? this.ciphertext,
    cipherVersion: cipherVersion ?? this.cipherVersion,
  );
}

/// All payment, provider, idempotency, state, and scope fields stay inside a
/// versioned native-keystore ciphertext. SQLite sees only opaque values.
final class EncryptedPaymentOutboxCodec {
  EncryptedPaymentOutboxCodec(this._cipher);

  static const int cipherVersion = 1;
  final PaymentOutboxCipher _cipher;

  Future<OutboxCiphertextRecord> seal(
    PaymentOutboxItem item, {
    required String recordId,
  }) async {
    _requireRecordId(recordId);
    try {
      return OutboxCiphertextRecord(
        recordId: recordId,
        ciphertext: await _cipher.encrypt(
          identity: recordId,
          cleartext: jsonEncode(<String, Object?>{
            'schema': cipherVersion,
            'tenant_id': item.scope.tenantId,
            'device_id': item.scope.deviceId,
            'provider': item.envelope.provider,
            'provider_reference': item.envelope.providerReference,
            'amount_minor': item.envelope.amountMinor,
            'currency': item.envelope.currency,
            'captured_at': item.envelope.capturedAt.toUtc().toIso8601String(),
            'idempotency_key': item.envelope.idempotencyKey,
            'state': item.state.name,
            'attempts': item.attempts,
            'created_at': item.createdAt.toUtc().toIso8601String(),
            'next_attempt_at': item.nextAttemptAt?.toUtc().toIso8601String(),
            'last_failure': item.lastFailure,
          }),
        ),
        cipherVersion: cipherVersion,
      );
    } on OutboxRecoveryRequiredException {
      rethrow;
    } catch (_) {
      throw const OutboxRecoveryRequiredException();
    }
  }

  Future<PaymentOutboxItem> open(OutboxCiphertextRecord record) async {
    if (record.cipherVersion != cipherVersion) {
      throw const OutboxRecoveryRequiredException();
    }
    try {
      final Object? decoded = jsonDecode(await _cipher.decrypt(
        identity: record.recordId,
        ciphertext: record.ciphertext,
      ));
      if (decoded is! Map<String, dynamic> || decoded['schema'] != cipherVersion) {
        throw const FormatException();
      }
      final OutboxScope scope = OutboxScope(
        tenantId: _string(decoded, 'tenant_id'),
        deviceId: _string(decoded, 'device_id'),
      );
      final PaymentEnvelope? envelope = PaymentEnvelope.create(
        scope: scope,
        provider: _string(decoded, 'provider'),
        providerReference: _string(decoded, 'provider_reference'),
        amountMinor: _int(decoded, 'amount_minor'),
        currency: _string(decoded, 'currency'),
        capturedAt: DateTime.parse(_string(decoded, 'captured_at')),
      );
      if (envelope == null || envelope.idempotencyKey != _string(decoded, 'idempotency_key')) {
        throw const FormatException();
      }
      return PaymentOutboxItem(
        envelope: envelope,
        state: PaymentOutboxState.values.byName(_string(decoded, 'state')),
        attempts: _int(decoded, 'attempts'),
        createdAt: DateTime.parse(_string(decoded, 'created_at')).toUtc(),
        nextAttemptAt: decoded['next_attempt_at'] == null
            ? null
            : DateTime.parse(_string(decoded, 'next_attempt_at')).toUtc(),
        lastFailure: decoded['last_failure'] as String?,
      );
    } on OutboxRecoveryRequiredException {
      rethrow;
    } catch (_) {
      throw const OutboxRecoveryRequiredException();
    }
  }

  static String _string(Map<String, dynamic> value, String key) {
    final Object? result = value[key];
    if (result is! String || result.isEmpty) throw const FormatException();
    return result;
  }

  static int _int(Map<String, dynamic> value, String key) {
    final Object? result = value[key];
    if (result is! int || result < 0) throw const FormatException();
    return result;
  }

  static void _requireRecordId(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const OutboxRecoveryRequiredException();
    }
  }
}

/// Sensitive V1 pages are copied into a fresh V2 ciphertext database. A
/// failed migration retries safely after restart; cipher/key failures never
/// expose or silently recreate data.
final class SqlitePaymentOutboxRepository implements PaymentOutboxRepository {
  SqlitePaymentOutboxRepository._(this._database, this._codec);

  final Database _database;
  final EncryptedPaymentOutboxCodec _codec;

  Future<void> close() => _database.close();

  static Future<SqlitePaymentOutboxRepository> open({
    PaymentOutboxCipher? cipher,
    PaymentOutboxStorageLocation? location,
  }) async {
    final PlatformPaymentOutboxCipher platform = const PlatformPaymentOutboxCipher();
    final EncryptedPaymentOutboxCodec codec = EncryptedPaymentOutboxCodec(cipher ?? platform);
    try {
      final String databasePath = join(
        await (location ?? platform).directory(),
        'opencongopay-outbox.db',
      );
      await _migrateLegacyDatabase(databasePath, codec);
      final Database database = await openDatabase(
        databasePath,
        version: 2,
        onCreate: (Database db, int _) => _createCiphertextTable(db),
        onUpgrade: (_, _, _) => throw const OutboxRecoveryRequiredException(),
      );
      return SqlitePaymentOutboxRepository._(database, codec);
    } on OutboxRecoveryRequiredException {
      rethrow;
    } catch (_) {
      throw const OutboxRecoveryRequiredException();
    }
  }

  static Future<void> _createCiphertextTable(DatabaseExecutor db, {String table = 'payment_outbox'}) =>
      db.execute('CREATE TABLE $table (record_id TEXT PRIMARY KEY, ciphertext TEXT NOT NULL, cipher_version INTEGER NOT NULL)');

  /// A V1 `DROP TABLE` can retain plaintext pages in the SQLite file. Copy
  /// rows into a fresh encrypted V2 file, verify every ciphertext record, then
  /// atomically cut it over before deleting the retained V1 file.
  static Future<void> _migrateLegacyDatabase(
    String databasePath,
    EncryptedPaymentOutboxCodec codec,
  ) async {
    final File sourceFile = File(databasePath);
    final String stagingPath = '$databasePath.v2-migration';
    final File stagingFile = File(stagingPath);
    final String cutoverPath = '$databasePath.v1-cutover';
    final File cutoverFile = File(cutoverPath);

    if (!sourceFile.existsSync()) {
      if (_sqliteFilesExist(cutoverPath)) {
        if (!cutoverFile.existsSync()) throw const OutboxRecoveryRequiredException();
        if (stagingFile.existsSync()) {
          final Map<String, PaymentOutboxItem> stagedItems =
              await _validateCiphertextDatabase(stagingPath, codec);
          await _validateLegacyDatabase(cutoverPath, stagedItems);
          await _promoteStaging(stagingPath, databasePath);
        }
        final Map<String, PaymentOutboxItem> activeItems =
            await _validateCiphertextDatabase(databasePath, codec);
        await _validateLegacyDatabase(cutoverPath, activeItems);
        await deleteDatabase(cutoverPath);
      } else if (stagingFile.existsSync()) {
        await _validateCiphertextDatabase(stagingPath, codec);
        await _promoteStaging(stagingPath, databasePath);
        await _validateCiphertextDatabase(databasePath, codec);
      }
      return;
    }
    if (_sqliteFilesExist(cutoverPath)) {
      if (!cutoverFile.existsSync() || stagingFile.existsSync()) {
        throw const OutboxRecoveryRequiredException();
      }

      final Map<String, PaymentOutboxItem> expectedItems =
          await _validateCiphertextDatabase(databasePath, codec);
      await _validateLegacyDatabase(cutoverPath, expectedItems);
      await deleteDatabase(cutoverPath);
      return;
    }
    if (stagingFile.existsSync()) await deleteDatabase(stagingPath);

    late List<String> expectedRecordIds;
    final Database source = await openDatabase(databasePath);
    try {
      final int version = (await source.rawQuery('PRAGMA user_version')).single.values.single as int;
      if (version == 2) return;
      if (version != 1) throw const OutboxRecoveryRequiredException();

      final List<PaymentOutboxItem> items = (await source.query('payment_outbox'))
          .map(_legacyItem)
          .toList(growable: false);
      expectedRecordIds = items.map(_recordId).toList(growable: false);
      final Database staging = await openDatabase(
        stagingPath,
        version: 2,
        onCreate: (Database db, int _) => _createCiphertextTable(db),
      );
      try {
        await staging.transaction((Transaction transaction) async {
          for (final PaymentOutboxItem item in items) {
            await transaction.insert(
              'payment_outbox',
              (await codec.seal(item, recordId: _recordId(item))).databaseValues,
            );
          }
        });
      } finally {
        await staging.close();
      }
    } finally {
      await source.close();
    }

    final Map<String, PaymentOutboxItem> stagedItems =
        await _validateCiphertextDatabase(stagingPath, codec, expectedRecordIds: expectedRecordIds);
    try {
      await _moveSqliteDatabase(databasePath, cutoverPath);
      await _validateLegacyDatabase(cutoverPath, stagedItems);
      await _promoteStaging(stagingPath, databasePath);
      final Map<String, PaymentOutboxItem> activeItems = await _validateCiphertextDatabase(
        databasePath,
        codec,
        expectedRecordIds: expectedRecordIds,
      );
      await _validateLegacyDatabase(cutoverPath, activeItems);
      await deleteDatabase(cutoverPath);
    } on FileSystemException {
      throw const OutboxRecoveryRequiredException();
    }
  }

  static Future<Map<String, PaymentOutboxItem>> _validateCiphertextDatabase(
    String databasePath,
    EncryptedPaymentOutboxCodec codec, {
    List<String>? expectedRecordIds,
  }) async {
    final Database database = await openDatabase(databasePath, readOnly: true);
    try {
      final int version = (await database.rawQuery('PRAGMA user_version')).single.values.single as int;
      if (version != 2) throw const OutboxRecoveryRequiredException();
      final List<Map<String, Object?>> rows = await database.query('payment_outbox');
      if (expectedRecordIds != null &&
          (rows.length != expectedRecordIds.length ||
              !rows.map((Map<String, Object?> row) => row['record_id']).toSet().containsAll(expectedRecordIds))) {
        throw const OutboxRecoveryRequiredException();
      }
      final Map<String, PaymentOutboxItem> items = <String, PaymentOutboxItem>{};
      for (final Map<String, Object?> row in rows) {
        final String recordId = row['record_id']! as String;
        final PaymentOutboxItem item = await codec.open(OutboxCiphertextRecord(
          recordId: recordId,
          ciphertext: row['ciphertext']! as String,
          cipherVersion: row['cipher_version']! as int,
        ));
        if (_recordId(item) != recordId || items.putIfAbsent(recordId, () => item) != item) {
          throw const OutboxRecoveryRequiredException();
        }
      }
      return items;
    } finally {
      await database.close();
    }
  }

  static Future<void> _validateLegacyDatabase(
    String databasePath,
    Map<String, PaymentOutboxItem> expectedItems,
  ) async {
    final Database database = await openDatabase(databasePath, readOnly: true);
    try {
      final int version = (await database.rawQuery('PRAGMA user_version')).single.values.single as int;
      if (version != 1) throw const OutboxRecoveryRequiredException();
      final Map<String, PaymentOutboxItem> legacyItems = <String, PaymentOutboxItem>{};
      for (final PaymentOutboxItem item in (await database.query('payment_outbox'))
          .map(_legacyItem)
          .toList(growable: false)) {
        final String recordId = _recordId(item);
        if (legacyItems.putIfAbsent(recordId, () => item) != item) {
          throw const OutboxRecoveryRequiredException();
        }
      }
      if (legacyItems.length != expectedItems.length ||
          legacyItems.entries.any((MapEntry<String, PaymentOutboxItem> entry) =>
              _canonicalItem(entry.value) != _canonicalItem(expectedItems[entry.key]))) {
        throw const OutboxRecoveryRequiredException();
      }
    } finally {
      await database.close();
    }
  }

  static String _canonicalItem(PaymentOutboxItem? item) {
    if (item == null) return '';
    return jsonEncode(<String, Object?>{
      'tenant_id': item.scope.tenantId,
      'device_id': item.scope.deviceId,
      'provider': item.envelope.provider,
      'provider_reference': item.envelope.providerReference,
      'amount_minor': item.envelope.amountMinor,
      'currency': item.envelope.currency,
      'captured_at': item.envelope.capturedAt.toUtc().toIso8601String(),
      'idempotency_key': item.envelope.idempotencyKey,
      'state': item.state.name,
      'attempts': item.attempts,
      'created_at': item.createdAt.toUtc().toIso8601String(),
      'next_attempt_at': item.nextAttemptAt?.toUtc().toIso8601String(),
      'last_failure': item.lastFailure,
    });
  }

  static Future<void> _promoteStaging(
    String stagingPath,
    String databasePath,
  ) async {
    try {
      await _moveSqliteDatabase(stagingPath, databasePath);
    } on FileSystemException {
      throw const OutboxRecoveryRequiredException();
    }
  }

  static Future<void> _moveSqliteDatabase(String sourcePath, String destinationPath) async {
    for (final String suffix in <String>['-journal', '-wal', '-shm', '']) {
      final File source = File('$sourcePath$suffix');
      if (!source.existsSync()) continue;
      final File destination = File('$destinationPath$suffix');
      if (destination.existsSync()) throw const FileSystemException();
      await source.rename(destination.path);
    }
  }

  static bool _sqliteFilesExist(String path) =>
      <String>['', '-journal', '-wal', '-shm'].any((String suffix) => File('$path$suffix').existsSync());

  @override
  Future<PaymentOutboxItem?> find(OutboxScope scope, String idempotencyKey) async {
    for (final PaymentOutboxItem item in await list(scope)) {
      if (item.envelope.idempotencyKey == idempotencyKey) return item;
    }
    return null;
  }

  @override
  Future<List<PaymentOutboxItem>> list(OutboxScope scope) async {
    final List<PaymentOutboxItem> items = await Future.wait(
      (await _database.query('payment_outbox')).map(_decode),
    );
    return (items.where((PaymentOutboxItem item) => item.scope == scope).toList()
          ..sort((PaymentOutboxItem left, PaymentOutboxItem right) {
            final int createdAt = left.createdAt.compareTo(right.createdAt);
            return createdAt != 0
                ? createdAt
                : left.envelope.idempotencyKey.compareTo(right.envelope.idempotencyKey);
          }))
        .toList(growable: false);
  }

  @override
  Future<PaymentOutboxItem> putIfAbsent(PaymentOutboxItem item) async {
    final PaymentOutboxItem? existing = await find(item.scope, item.envelope.idempotencyKey);
    if (existing != null) return existing;
    final OutboxCiphertextRecord record = await _codec.seal(item, recordId: _recordId(item));
    await _database.insert('payment_outbox', record.databaseValues, conflictAlgorithm: ConflictAlgorithm.ignore);
    return (await find(item.scope, item.envelope.idempotencyKey))!;
  }

  @override
  Future<bool> replace(PaymentOutboxItem item, {required PaymentOutboxState expectedState}) async {
    final String recordId = _recordId(item);
    final List<Map<String, Object?>> rows = await _database.query('payment_outbox', where: 'record_id = ?', whereArgs: <Object>[recordId], limit: 1);
    if (rows.length != 1 || (await _decode(rows.single)).state != expectedState) return false;
    final OutboxCiphertextRecord record = await _codec.seal(item, recordId: recordId);
    return await _database.update(
          'payment_outbox',
          record.databaseValues,
          where: 'record_id = ? AND ciphertext = ?',
          whereArgs: <Object>[recordId, rows.single['ciphertext']!],
        ) ==
        1;
  }

  Future<PaymentOutboxItem> _decode(Map<String, Object?> row) => _codec.open(OutboxCiphertextRecord(
    recordId: row['record_id']! as String,
    ciphertext: row['ciphertext']! as String,
    cipherVersion: row['cipher_version']! as int,
  ));

  static PaymentOutboxItem _legacyItem(Map<String, Object?> row) {
    final Map<String, dynamic> envelope = jsonDecode(row['envelope_json']! as String) as Map<String, dynamic>;
    final OutboxScope scope = OutboxScope(tenantId: row['tenant_id']! as String, deviceId: row['device_id']! as String);
    final PaymentEnvelope value = PaymentEnvelope.create(
      scope: scope,
      provider: envelope['provider']! as String,
      providerReference: envelope['provider_reference']! as String,
      amountMinor: envelope['amount_minor']! as int,
      currency: envelope['currency']! as String,
      capturedAt: DateTime.parse(envelope['captured_at']! as String),
    )!;
    if (value.idempotencyKey != row['idempotency_key']) throw const OutboxRecoveryRequiredException();
    return PaymentOutboxItem(
      envelope: value,
      state: PaymentOutboxState.values.byName(row['state']! as String),
      attempts: row['attempts']! as int,
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      nextAttemptAt: row['next_attempt_at'] == null ? null : DateTime.parse(row['next_attempt_at']! as String).toUtc(),
      lastFailure: row['last_failure'] as String?,
    );
  }

  static String _recordId(PaymentOutboxItem item) => sha256.convert(utf8.encode(
    '${item.scope.tenantId}|${item.scope.deviceId}|${item.envelope.idempotencyKey}',
  )).toString();
}
