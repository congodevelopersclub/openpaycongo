import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox.dart';
import 'package:opencongopay/features/payment_outbox/domain/payment_outbox_sync_coordinator.dart';

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
      records.putIfAbsent(_key(item.scope, item.envelope.idempotencyKey), () => item);

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

final class FakeCredentials implements PaymentSyncCredentialProvider {
  FakeCredentials(this.credential);

  PaymentSyncCredential? credential;
  int calls = 0;

  @override
  Future<PaymentSyncCredential?> load(OutboxScope scope) async {
    calls++;
    return credential;
  }
}

final class FakeTransport implements PaymentSyncTransport {
  FakeTransport({this.response, this.offline = false});

  PaymentSyncResponse? response;
  bool offline;
  final List<PaymentSyncRequest> requests = <PaymentSyncRequest>[];

  @override
  Future<PaymentSyncResponse> send(PaymentSyncRequest request) async {
    requests.add(request);
    if (offline) throw const PaymentSyncUnavailable();
    return response!;
  }
}

const OutboxScope scope = OutboxScope(
  tenantId: 'tenant-001',
  deviceId: 'device-001',
);
final DateTime now = DateTime.utc(2026, 8, 15, 10);

PaymentEnvelope envelope(String reference) => PaymentEnvelope.create(
  scope: scope,
  provider: 'MOBILEMONEY',
  providerReference: reference,
  amountMinor: 1250,
  currency: 'USD',
  capturedAt: now,
)!;

void main() {
  PaymentOutboxSyncCoordinator coordinator(
    MemoryOutboxRepository repository,
    FakeCredentials credentials,
    FakeTransport transport, {
    int maxBatch = 10,
  }) =>
      PaymentOutboxSyncCoordinator(
        outbox: PaymentOutbox(repository),
        credentials: credentials,
        transport: transport,
        maxBatch: maxBatch,
      );

  test('acknowledges only exact batch keys and defers partial duplicate acknowledgements', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository);
    final PaymentOutboxItem first = await outbox.enqueue(envelope('REF-1001'));
    final PaymentOutboxItem second = await outbox.enqueue(envelope('REF-1002'));
    final FakeTransport transport = FakeTransport(
      response: PaymentSyncResponse(
        acknowledgedIdempotencyKeys: <String>[
          first.envelope.idempotencyKey,
          first.envelope.idempotencyKey,
          'not-in-this-batch',
        ],
        retryAfter: const Duration(minutes: 7),
      ),
    );
    final PaymentOutboxSyncCoordinator subject = coordinator(
      repository,
      FakeCredentials(const PaymentSyncCredential('opaque')),
      transport,
      maxBatch: 2,
    );

    final PaymentSyncRun run = await subject.sync(scope, now);
    final PaymentOutboxItem? storedFirst = await repository.find(
      scope,
      first.envelope.idempotencyKey,
    );
    final PaymentOutboxItem? storedSecond = await repository.find(
      scope,
      second.envelope.idempotencyKey,
    );

    expect(run.outcome, PaymentSyncOutcome.partial);
    expect(run.acknowledged, 1);
    expect(run.deferred, 1);
    expect(transport.requests.single.items, hasLength(2));
    expect(storedFirst!.state, PaymentOutboxState.acknowledged);
    expect(storedSecond!.state, PaymentOutboxState.failed);
    expect(storedSecond.nextAttemptAt, now.add(const Duration(minutes: 7)));
  });

  test('recovers an interrupted in-flight item and retries it with its stable key', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox firstProcess = PaymentOutbox(repository);
    final PaymentOutboxItem item = await firstProcess.enqueue(envelope('REF-1003'));
    await firstProcess.claimNext(scope, now);
    final FakeTransport transport = FakeTransport(
      response: PaymentSyncResponse(
        acknowledgedIdempotencyKeys: <String>[item.envelope.idempotencyKey],
      ),
    );

    final PaymentSyncRun run = await coordinator(
      repository,
      FakeCredentials(const PaymentSyncCredential('opaque')),
      transport,
    ).sync(scope, now.add(const Duration(minutes: 1)));

    expect(run.recovered, 1);
    expect(transport.requests.single.items.single.envelope.idempotencyKey, item.envelope.idempotencyKey);
    expect((await repository.find(scope, item.envelope.idempotencyKey))!.state, PaymentOutboxState.acknowledged);
  });

  test('missing credentials or cancellation fails safe without transport or claims', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository);
    final PaymentOutboxItem item = await outbox.enqueue(envelope('REF-1004'));
    final FakeCredentials credentials = FakeCredentials(null);
    final FakeTransport transport = FakeTransport();
    final PaymentOutboxSyncCoordinator subject = coordinator(repository, credentials, transport);

    final PaymentSyncRun offline = await subject.sync(scope, now);
    final PaymentSyncRun cancelled = await subject.sync(
      scope,
      now,
      cancellation: const CancelledPaymentSync(),
    );

    expect(offline.outcome, PaymentSyncOutcome.offline);
    expect(cancelled.outcome, PaymentSyncOutcome.cancelled);
    expect(credentials.calls, 1);
    expect(transport.requests, isEmpty);
    expect((await repository.find(scope, item.envelope.idempotencyKey))!.state, PaymentOutboxState.pending);
  });

  test('an offline transport defers claimed items using bounded backoff metadata', () async {
    final MemoryOutboxRepository repository = MemoryOutboxRepository();
    final PaymentOutbox outbox = PaymentOutbox(repository);
    final PaymentOutboxItem item = await outbox.enqueue(envelope('REF-1005'));
    final FakeTransport transport = FakeTransport(offline: true);

    final PaymentSyncRun run = await coordinator(
      repository,
      FakeCredentials(const PaymentSyncCredential('opaque')),
      transport,
    ).sync(scope, now);
    final PaymentOutboxItem stored =
        (await repository.find(scope, item.envelope.idempotencyKey))!;

    expect(run.outcome, PaymentSyncOutcome.offline);
    expect(run.deferred, 1);
    expect(stored.state, PaymentOutboxState.failed);
    expect(stored.nextAttemptAt, now.add(const Duration(minutes: 1)));
  });
}
