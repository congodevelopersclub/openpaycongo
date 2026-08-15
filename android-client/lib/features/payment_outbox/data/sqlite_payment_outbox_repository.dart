import 'dart:convert';

import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Durable on-device persistence only; no network or transport behavior lives here.
final class SqlitePaymentOutboxRepository implements PaymentOutboxRepository {
  SqlitePaymentOutboxRepository._(this._database);
  final Database _database;

  static Future<SqlitePaymentOutboxRepository> open() async {
    final String directory = (await getApplicationDocumentsDirectory()).path;
    final Database database = await openDatabase(
      join(directory, 'opencongopay-outbox.db'),
      version: 1,
      onCreate: (Database db, int _) => db.execute('''
        CREATE TABLE payment_outbox (
          tenant_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          idempotency_key TEXT NOT NULL,
          envelope_json TEXT NOT NULL,
          state TEXT NOT NULL,
          attempts INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          next_attempt_at TEXT,
          last_failure TEXT,
          PRIMARY KEY (tenant_id, device_id, idempotency_key)
        )
      '''),
    );
    return SqlitePaymentOutboxRepository._(database);
  }

  @override
  Future<PaymentOutboxItem?> find(OutboxScope scope, String idempotencyKey) async {
    final List<Map<String, Object?>> rows = await _database.query(
      'payment_outbox',
      where: 'tenant_id = ? AND device_id = ? AND idempotency_key = ?',
      whereArgs: <Object>[scope.tenantId, scope.deviceId, idempotencyKey],
      limit: 1,
    );
    return rows.isEmpty ? null : _item(rows.single);
  }

  @override
  Future<List<PaymentOutboxItem>> list(OutboxScope scope) async =>
      (await _database.query(
        'payment_outbox',
        where: 'tenant_id = ? AND device_id = ?',
        whereArgs: <Object>[scope.tenantId, scope.deviceId],
        orderBy: 'created_at ASC, idempotency_key ASC',
      )).map(_item).toList(growable: false);

  @override
  Future<PaymentOutboxItem> putIfAbsent(PaymentOutboxItem item) async {
    await _database.insert(
      'payment_outbox',
      _values(item),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return (await find(item.scope, item.envelope.idempotencyKey))!;
  }

  @override
  Future<bool> replace(
    PaymentOutboxItem item, {
    required PaymentOutboxState expectedState,
  }) async =>
      await _database.update(
        'payment_outbox',
        _values(item),
        where: 'tenant_id = ? AND device_id = ? AND idempotency_key = ? AND state = ?',
        whereArgs: <Object>[
          item.scope.tenantId,
          item.scope.deviceId,
          item.envelope.idempotencyKey,
          expectedState.name,
        ],
      ) == 1;

  Map<String, Object?> _values(PaymentOutboxItem item) => <String, Object?>{
    'tenant_id': item.scope.tenantId,
    'device_id': item.scope.deviceId,
    'idempotency_key': item.envelope.idempotencyKey,
    'envelope_json': jsonEncode(item.envelope.toMap()),
    'state': item.state.name,
    'attempts': item.attempts,
    'created_at': item.createdAt.toUtc().toIso8601String(),
    'next_attempt_at': item.nextAttemptAt?.toUtc().toIso8601String(),
    'last_failure': item.lastFailure,
  };

  PaymentOutboxItem _item(Map<String, Object?> row) {
    final Map<String, dynamic> envelope =
        jsonDecode(row['envelope_json']! as String) as Map<String, dynamic>;
    final OutboxScope scope = OutboxScope(
      tenantId: row['tenant_id']! as String,
      deviceId: row['device_id']! as String,
    );
    final PaymentEnvelope value = PaymentEnvelope.create(
      scope: scope,
      provider: envelope['provider']! as String,
      providerReference: envelope['provider_reference']! as String,
      amountMinor: envelope['amount_minor']! as int,
      currency: envelope['currency']! as String,
      capturedAt: DateTime.parse(envelope['captured_at']! as String),
    )!;
    if (value.idempotencyKey != row['idempotency_key']) {
      throw StateError('outbox envelope integrity mismatch');
    }
    return PaymentOutboxItem(
      envelope: value,
      state: PaymentOutboxState.values.byName(row['state']! as String),
      attempts: row['attempts']! as int,
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      nextAttemptAt: row['next_attempt_at'] == null
          ? null
          : DateTime.parse(row['next_attempt_at']! as String).toUtc(),
      lastFailure: row['last_failure'] as String?,
    );
  }
}
