import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/data/sqlite_payment_outbox_repository.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class MemoryOutboxCipher implements PaymentOutboxCipher {
  final Map<String, String> _cleartexts = <String, String>{};

  @override
  Future<String> decrypt({required String identity, required String ciphertext}) async =>
      _cleartexts['$identity/$ciphertext']!;

  @override
  Future<String> encrypt({required String identity, required String cleartext}) async {
    final String ciphertext = sha256
        .convert(utf8.encode('$identity/$cleartext'))
        .toString();
    _cleartexts['$identity/$ciphertext'] = cleartext;
    return ciphertext;
  }
}

final class UnavailableOutboxCipher implements PaymentOutboxCipher {
  const UnavailableOutboxCipher();

  @override
  Future<String> decrypt({required String identity, required String ciphertext}) =>
      throw const OutboxRecoveryRequiredException();

  @override
  Future<String> encrypt({required String identity, required String cleartext}) =>
      throw const OutboxRecoveryRequiredException();
}

final class EncryptsButCannotDecryptCipher implements PaymentOutboxCipher {
  const EncryptsButCannotDecryptCipher();

  @override
  Future<String> decrypt({required String identity, required String ciphertext}) =>
      throw const OutboxRecoveryRequiredException();

  @override
  Future<String> encrypt({required String identity, required String cleartext}) async =>
      'opaque-native-ciphertext';
}

final class TestOutboxStorageLocation implements PaymentOutboxStorageLocation {
  const TestOutboxStorageLocation(this.path);

  final String path;

  @override
  Future<String> directory() async => path;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const OutboxScope scope = OutboxScope(
    tenantId: 'tenant-sensitive-001',
    deviceId: 'device-sensitive-001',
  );
  final PaymentOutboxItem item = PaymentOutboxItem(
    envelope: PaymentEnvelope.create(
      scope: scope,
      provider: 'MOBILEMONEY',
      providerReference: 'REF-SENSITIVE-001',
      amountMinor: 12500,
      currency: 'CDF',
      capturedAt: DateTime.utc(2026, 8, 30, 1),
    )!,
    state: PaymentOutboxState.pending,
    attempts: 0,
    createdAt: DateTime.utc(2026, 8, 30, 1),
  );

  test('versioned ciphertext rows contain no payment, provider, idempotency, or scope data', () async {
    final EncryptedPaymentOutboxCodec codec = EncryptedPaymentOutboxCodec(
      MemoryOutboxCipher(),
    );

    final OutboxCiphertextRecord record = await codec.seal(
      item,
      recordId: 'a' * 64,
    );
    final String raw = jsonEncode(record.databaseValues);

    expect(record.databaseValues.keys, <String>{'record_id', 'ciphertext', 'cipher_version'});
    expect(raw, isNot(contains(scope.tenantId)));
    expect(raw, isNot(contains(scope.deviceId)));
    expect(raw, isNot(contains(item.envelope.providerReference)));
    expect(raw, isNot(contains(item.envelope.idempotencyKey)));
    expect(raw, isNot(contains(item.envelope.amountMinor.toString())));
    final restored = await codec.open(record);

    expect(restored.scope, item.scope);
    expect(restored.envelope.provider, item.envelope.provider);
    expect(restored.envelope.providerReference, item.envelope.providerReference);
    expect(restored.envelope.amountMinor, item.envelope.amountMinor);
    expect(restored.envelope.currency, item.envelope.currency);
    expect(restored.envelope.capturedAt, item.envelope.capturedAt);
    expect(restored.envelope.idempotencyKey, item.envelope.idempotencyKey);
    expect(restored.state, item.state);
  });

  test('ciphertext version and identity tampering fail closed', () async {
    final EncryptedPaymentOutboxCodec codec = EncryptedPaymentOutboxCodec(
      MemoryOutboxCipher(),
    );
    final OutboxCiphertextRecord record = await codec.seal(
      item,
      recordId: 'a' * 64,
    );

    await expectLater(
      codec.open(record.copyWith(cipherVersion: 2)),
      throwsA(isA<OutboxRecoveryRequiredException>()),
    );
    await expectLater(
      codec.open(record.copyWith(recordId: 'b' * 64)),
      throwsA(isA<OutboxRecoveryRequiredException>()),
    );
  });

  test('unavailable keystore boundary remains recovery-required', () async {
    final EncryptedPaymentOutboxCodec codec = EncryptedPaymentOutboxCodec(
      const UnavailableOutboxCipher(),
    );

    await expectLater(
      codec.seal(item, recordId: 'a' * 64),
      throwsA(isA<OutboxRecoveryRequiredException>()),
    );
  });

  test('raw SQLite contains only ciphertext record columns and no sensitive values', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-test-');
    final SqlitePaymentOutboxRepository repository = await SqlitePaymentOutboxRepository.open(
      cipher: MemoryOutboxCipher(),
      location: TestOutboxStorageLocation(directory.path),
    );
    final String databasePath = join(directory.path, 'opencongopay-outbox.db');
    try {
      await repository.putIfAbsent(item);
      await repository.close();

      final Database database = await openDatabase(databasePath, readOnly: true);
      final List<Map<String, Object?>> columns = await database.rawQuery('PRAGMA table_info(payment_outbox)');
      await database.close();
      final String raw = String.fromCharCodes(await File(databasePath).readAsBytes());

      expect(columns.map((Map<String, Object?> column) => column['name']), <String>[
        'record_id',
        'ciphertext',
        'cipher_version',
      ]);
      expect(raw, isNot(contains(scope.tenantId)));
      expect(raw, isNot(contains(scope.deviceId)));
      expect(raw, isNot(contains(item.envelope.providerReference)));
      expect(raw, isNot(contains(item.envelope.idempotencyKey)));
      expect(raw, isNot(contains(item.envelope.amountMinor.toString())));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('V1 migration restarts from incomplete staging and leaves no plaintext pages', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-migration-');
    final String databasePath = join(directory.path, 'opencongopay-outbox.db');
    await _writeV1Database(databasePath, item);
    await File('$databasePath.v2-migration').writeAsString('incomplete-stage');
    final SqlitePaymentOutboxRepository repository = await SqlitePaymentOutboxRepository.open(
      cipher: MemoryOutboxCipher(),
      location: TestOutboxStorageLocation(directory.path),
    );
    try {
      expect(await repository.find(scope, item.envelope.idempotencyKey), isNotNull);
      await repository.close();

      final String raw = String.fromCharCodes(await File(databasePath).readAsBytes());

      expect(File('$databasePath.v2-migration').existsSync(), isFalse);
      expect(File('$databasePath.v1-cutover').existsSync(), isFalse);
      expect(raw, isNot(contains(scope.tenantId)));
      expect(raw, isNot(contains(scope.deviceId)));
      expect(raw, isNot(contains(item.envelope.providerReference)));
      expect(raw, isNot(contains(item.envelope.idempotencyKey)));
      expect(raw, isNot(contains(item.envelope.amountMinor.toString())));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('decrypt validation failure leaves V1 plaintext untouched before cutover', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-cutover-');
    final String databasePath = join(directory.path, 'opencongopay-outbox.db');
    await _writeV1Database(databasePath, item);
    try {
      await expectLater(
        SqlitePaymentOutboxRepository.open(
          cipher: const EncryptsButCannotDecryptCipher(),
          location: TestOutboxStorageLocation(directory.path),
        ),
        throwsA(isA<OutboxRecoveryRequiredException>()),
      );

      final String original = String.fromCharCodes(await File(databasePath).readAsBytes());

      expect(original, contains(scope.tenantId));
      expect(File('$databasePath.v1-cutover').existsSync(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('post-promotion restart validates matching V1 cutover before deleting plaintext', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-promoted-');
    final String databasePath = join(directory.path, 'opencongopay-outbox.db');
    final MemoryOutboxCipher cipher = MemoryOutboxCipher();
    try {
      await _writeV1Database(databasePath, item);
      final SqlitePaymentOutboxRepository promoted = await SqlitePaymentOutboxRepository.open(
        cipher: cipher,
        location: TestOutboxStorageLocation(directory.path),
      );
      await promoted.close();

      await _writeV1Database('$databasePath.v1-cutover', item);
      final SqlitePaymentOutboxRepository recovered = await SqlitePaymentOutboxRepository.open(
        cipher: cipher,
        location: TestOutboxStorageLocation(directory.path),
      );
      try {
        expect(await recovered.find(scope, item.envelope.idempotencyKey), isNotNull);
        expect(File('$databasePath.v1-cutover').existsSync(), isFalse);
      } finally {
        await recovered.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('post-promotion restart preserves V1 cutover when durable content conflicts', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-conflict-');
    final String databasePath = join(directory.path, 'opencongopay-outbox.db');
    final MemoryOutboxCipher cipher = MemoryOutboxCipher();
    try {
      await _writeV1Database(databasePath, item);
      final SqlitePaymentOutboxRepository promoted = await SqlitePaymentOutboxRepository.open(
        cipher: cipher,
        location: TestOutboxStorageLocation(directory.path),
      );
      await promoted.close();

      await _writeV1Database(
        '$databasePath.v1-cutover',
        item.copy(
          state: PaymentOutboxState.failed,
          attempts: 1,
          nextAttemptAt: DateTime.utc(2026, 8, 30, 3),
          lastFailure: 'network_error',
        ),
      );
      await expectLater(
        SqlitePaymentOutboxRepository.open(
          cipher: cipher,
          location: TestOutboxStorageLocation(directory.path),
        ),
        throwsA(isA<OutboxRecoveryRequiredException>()),
      );
      expect(File('$databasePath.v1-cutover').existsSync(), isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('mid-cutover restart preserves divergent V1 and V2 staging databases', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-mid-cutover-');
    final String databasePath = join(directory.path, 'opencongopay-outbox.db');
    final MemoryOutboxCipher cipher = MemoryOutboxCipher();
    try {
      await _writeV1Database(databasePath, item);
      final SqlitePaymentOutboxRepository encrypted = await SqlitePaymentOutboxRepository.open(
        cipher: cipher,
        location: TestOutboxStorageLocation(directory.path),
      );
      await encrypted.close();

      await File(databasePath).copy('$databasePath.v2-migration');
      await deleteDatabase(databasePath);
      await _writeV1Database(
        '$databasePath.v1-cutover',
        item.copy(
          state: PaymentOutboxState.failed,
          attempts: 1,
          nextAttemptAt: DateTime.utc(2026, 8, 30, 3),
          lastFailure: 'network_error',
        ),
      );

      await expectLater(
        SqlitePaymentOutboxRepository.open(
          cipher: cipher,
          location: TestOutboxStorageLocation(directory.path),
        ),
        throwsA(isA<OutboxRecoveryRequiredException>()),
      );

      expect(File(databasePath).existsSync(), isFalse);
      expect(File('$databasePath.v1-cutover').existsSync(), isTrue);
      expect(File('$databasePath.v2-migration').existsSync(), isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('encrypted rows preserve deterministic created-at and idempotency order', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-order-');
    final SqlitePaymentOutboxRepository repository = await SqlitePaymentOutboxRepository.open(
      cipher: MemoryOutboxCipher(),
      location: TestOutboxStorageLocation(directory.path),
    );
    final PaymentOutboxItem later = PaymentOutboxItem(
      envelope: PaymentEnvelope.create(
        scope: scope,
        provider: 'MOBILEMONEY',
        providerReference: 'REF-SENSITIVE-002',
        amountMinor: 12600,
        currency: 'CDF',
        capturedAt: DateTime.utc(2026, 8, 30, 2),
      )!,
      state: PaymentOutboxState.pending,
      attempts: 0,
      createdAt: DateTime.utc(2026, 8, 30, 2),
    );
    try {
      await repository.putIfAbsent(later);
      await repository.putIfAbsent(item);

      expect(
        (await repository.list(scope)).map((PaymentOutboxItem value) => value.envelope.idempotencyKey),
        <String>[item.envelope.idempotencyKey, later.envelope.idempotencyKey],
      );
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('encrypted replacement preserves the BLoC lifecycle compare-and-set boundary', () async {
    final Directory directory = await Directory.systemTemp.createTemp('openpay-outbox-state-');
    final SqlitePaymentOutboxRepository repository = await SqlitePaymentOutboxRepository.open(
      cipher: MemoryOutboxCipher(),
      location: TestOutboxStorageLocation(directory.path),
    );
    try {
      await repository.putIfAbsent(item);
      final PaymentOutboxItem inFlight = item.copy(state: PaymentOutboxState.inFlight);

      expect(
        await repository.replace(inFlight, expectedState: PaymentOutboxState.pending),
        isTrue,
      );
      expect(
        await repository.replace(
          item.copy(state: PaymentOutboxState.acknowledged),
          expectedState: PaymentOutboxState.pending,
        ),
        isFalse,
      );
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });
}

Future<void> _writeV1Database(String path, PaymentOutboxItem item) async {
  final Database database = await openDatabase(
    path,
    version: 1,
    onCreate: (Database db, int _) => db.execute(
      'CREATE TABLE payment_outbox ('
      'tenant_id TEXT NOT NULL, '
      'device_id TEXT NOT NULL, '
      'idempotency_key TEXT NOT NULL, '
      'envelope_json TEXT NOT NULL, '
      'state TEXT NOT NULL, '
      'attempts INTEGER NOT NULL, '
      'created_at TEXT NOT NULL, '
      'next_attempt_at TEXT NULL, '
      'last_failure TEXT NULL, '
      'PRIMARY KEY (tenant_id, device_id, idempotency_key)'
      ')',
    ),
  );
  try {
    await database.insert('payment_outbox', <String, Object?>{
      'tenant_id': item.scope.tenantId,
      'device_id': item.scope.deviceId,
      'idempotency_key': item.envelope.idempotencyKey,
      'envelope_json': jsonEncode(<String, Object>{
        'provider': item.envelope.provider,
        'provider_reference': item.envelope.providerReference,
        'amount_minor': item.envelope.amountMinor,
        'currency': item.envelope.currency,
        'captured_at': item.envelope.capturedAt.toUtc().toIso8601String(),
      }),
      'state': item.state.name,
      'attempts': item.attempts,
      'created_at': item.createdAt.toUtc().toIso8601String(),
      'next_attempt_at': item.nextAttemptAt?.toUtc().toIso8601String(),
      'last_failure': item.lastFailure,
    });
  } finally {
    await database.close();
  }
}
