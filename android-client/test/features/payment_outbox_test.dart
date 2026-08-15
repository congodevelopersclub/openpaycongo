import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';

final class MemoryOutboxRepository implements PaymentOutboxRepository {
  final Map<String, PaymentOutboxItem> records = <String, PaymentOutboxItem>{};

  String _key(OutboxScope scope, String idempotencyKey) =>
      '${scope.tenantId}/${scope.deviceId}/$idempotencyKey';

  @override
  Future<PaymentOutboxItem?> find(OutboxScope scope, String idempotencyKey) async =>
      records[_key(scope, idempotencyKey)];

  @override
  Future<List<PaymentOutboxItem>> list(OutboxScope scope) async => records.values
      .where((PaymentOutboxItem item) => item.scope == scope)
      .toList(growable: false);

  @override
  Future<PaymentOutboxItem> putIfAbsent(PaymentOutboxItem item) async =>
      records.putIfAbsent(
        _key(item.scope, item.envelope.idempotencyKey),
        () => item,
      );

  @override
  Future<bool> replace(
    PaymentOutboxItem item, {
    required PaymentOutboxState expectedState,
  }) async {
    final String key = _key(item.scope, item.envelope.idempotencyKey);
    final PaymentOutboxItem? existing = records[key];
    if (existing == null || existing.state != expectedState) return false;
    records[key] = item;
    return true;
  }
}

void main() {
  const OutboxScope scope = OutboxScope(
    tenantId: 'tenant-001',
    deviceId: 'device-001',
  );
  final DateTime now = DateTime.utc(2026, 8, 15, 10);
  PaymentEnvelope envelope({int amountMinor = 1250}) => PaymentEnvelope.create(
    scope: scope,
    provider: 'MOBILEMONEY',
    providerReference: 'REF-1234',
    amountMinor: amountMinor,
    currency: 'USD',
    capturedAt: now,
  )!;

  test('persists an immutable scoped envelope with a stable idempotency key', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository);

    final PaymentOutboxItem first = await outbox.enqueue(envelope());
    final PaymentOutboxItem replay = await outbox.enqueue(envelope());

    expect(first.envelope.idempotencyKey, replay.envelope.idempotencyKey);
    expect(replay, same(first));
    expect(
      () => first.envelope.toMap()['provider'] = 'OTHER',
      throwsUnsupportedError,
    );
    expect(await repository.list(scope), hasLength(1));
  });

  test('recovery turns an interrupted claim back to pending after restart', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox firstProcess = PaymentOutbox(repository);
    await firstProcess.enqueue(envelope());
    final PaymentOutboxItem claimed = (await firstProcess.claimNext(scope, now))!;
    expect(claimed.state, PaymentOutboxState.inFlight);

    final PaymentOutbox restarted = PaymentOutbox(repository);
    final List<PaymentOutboxItem> recovered = await restarted.recover(scope, now);

    expect(recovered.single.state, PaymentOutboxState.pending);
    expect((await restarted.claimNext(scope, now))!.state, PaymentOutboxState.inFlight);
  });

  test('acknowledgement is terminal and cannot be replayed', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository);
    await outbox.enqueue(envelope());
    final PaymentOutboxItem claimed = (await outbox.claimNext(scope, now))!;

    final PaymentOutboxItem acknowledged = await outbox.acknowledge(claimed);

    expect(acknowledged.state, PaymentOutboxState.acknowledged);
    expect(await outbox.claimNext(scope, now.add(const Duration(days: 1))), isNull);
  });

  test('failures are bounded, delayed, and retry-safe', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository, maxAttempts: 2);
    await outbox.enqueue(envelope());
    final PaymentOutboxItem first = (await outbox.claimNext(scope, now))!;
    final PaymentOutboxItem failed = await outbox.fail(
      first,
      now,
      reason: 'network_unavailable',
    );

    expect(failed.state, PaymentOutboxState.failed);
    expect(failed.attempts, 1);
    expect(await outbox.claimNext(scope, now), isNull);
    final PaymentOutboxItem second =
        (await outbox.claimNext(scope, failed.nextAttemptAt!))!;
    final PaymentOutboxItem terminal = await outbox.fail(
      second,
      failed.nextAttemptAt!,
      reason: 'network_unavailable',
    );
    expect(terminal.attempts, 2);
    expect(terminal.nextAttemptAt, isNull);
    expect(await outbox.claimNext(scope, now.add(const Duration(days: 1))), isNull);
  });

  test('scope and stale transition guards fail closed', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository);
    await outbox.enqueue(envelope());
    final PaymentOutboxItem claimed = (await outbox.claimNext(scope, now))!;

    await expectLater(outbox.acknowledge(claimed.copy(state: PaymentOutboxState.pending)), throwsStateError);
    expect(await outbox.claimNext(
      const OutboxScope(tenantId: 'tenant-002', deviceId: 'device-001'),
      now,
    ), isNull);
  });
}
