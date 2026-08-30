import 'payment_outbox.dart';

/// Opaque credential material. Selection, storage, parsing, and issuance stay outside this module.
final class PaymentSyncCredential {
  const PaymentSyncCredential(this.value);

  final String value;
}

abstract interface class PaymentSyncCredentialProvider {
  Future<PaymentSyncCredential?> load(OutboxScope scope);
}

final class PaymentSyncRequest {
  const PaymentSyncRequest({
    required this.scope,
    required this.credential,
    required this.items,
  });

  final OutboxScope scope;
  final PaymentSyncCredential credential;
  final List<PaymentOutboxItem> items;

  /// Safe for aggregate operational telemetry only. It deliberately excludes
  /// credentials, installation/customer scope, provider evidence, money, and
  /// idempotency material.
  Map<String, Object> redactedTelemetry() => <String, Object>{
    'item_count': items.length,
  };
}

final class PaymentSyncResponse {
  const PaymentSyncResponse({
    required this.acknowledgedIdempotencyKeys,
    this.retryAfter,
  });

  final Iterable<String> acknowledgedIdempotencyKeys;
  final Duration? retryAfter;
}

abstract interface class PaymentSyncTransport {
  Future<PaymentSyncResponse> send(PaymentSyncRequest request);
}

final class PaymentSyncUnavailable implements Exception {
  const PaymentSyncUnavailable();
}

abstract interface class PaymentSyncCancellation {
  bool get isCancelled;
}

final class ActivePaymentSync implements PaymentSyncCancellation {
  const ActivePaymentSync();

  @override
  bool get isCancelled => false;
}

final class CancelledPaymentSync implements PaymentSyncCancellation {
  const CancelledPaymentSync();

  @override
  bool get isCancelled => true;
}

enum PaymentSyncOutcome { completed, partial, offline, cancelled }

final class PaymentSyncRun {
  const PaymentSyncRun({
    required this.outcome,
    required this.recovered,
    required this.claimed,
    required this.acknowledged,
    required this.deferred,
  });

  final PaymentSyncOutcome outcome;
  final int recovered;
  final int claimed;
  final int acknowledged;
  final int deferred;
}

/// Internal coordinator only. Transport and credential policy are injected by a future owner.
final class PaymentOutboxSyncCoordinator {
  PaymentOutboxSyncCoordinator({
    required this.outbox,
    required this.credentials,
    required this.transport,
    this.maxBatch = 20,
  }) : assert(maxBatch > 0 && maxBatch <= 100);

  final PaymentOutbox outbox;
  final PaymentSyncCredentialProvider credentials;
  final PaymentSyncTransport transport;
  final int maxBatch;

  Future<PaymentSyncRun> sync(
    OutboxScope scope,
    DateTime now, {
    PaymentSyncCancellation cancellation = const ActivePaymentSync(),
  }) async {
    final DateTime normalized = now.toUtc();
    if (cancellation.isCancelled) return _run(PaymentSyncOutcome.cancelled);

    final List<PaymentOutboxItem> recovered = await outbox.recover(scope, normalized);
    if (cancellation.isCancelled) {
      return _run(PaymentSyncOutcome.cancelled, recovered: recovered.length);
    }
    final PaymentSyncCredential? credential = await credentials.load(scope);
    if (credential == null) return _run(PaymentSyncOutcome.offline, recovered: recovered.length);
    if (cancellation.isCancelled) {
      return _run(PaymentSyncOutcome.cancelled, recovered: recovered.length);
    }

    final List<PaymentOutboxItem> claimed = <PaymentOutboxItem>[];
    for (int index = 0; index < maxBatch; index++) {
      if (cancellation.isCancelled) {
        return _defer(claimed, normalized, PaymentSyncOutcome.cancelled, recovered.length);
      }
      final PaymentOutboxItem? item = await outbox.claimNext(scope, normalized);
      if (item == null) break;
      claimed.add(item);
    }
    if (claimed.isEmpty) return _run(PaymentSyncOutcome.completed, recovered: recovered.length);
    if (cancellation.isCancelled) {
      return _defer(claimed, normalized, PaymentSyncOutcome.cancelled, recovered.length);
    }

    try {
      final PaymentSyncResponse response = await transport.send(PaymentSyncRequest(
        scope: scope,
        credential: credential,
        items: List<PaymentOutboxItem>.unmodifiable(claimed),
      ));
      if (cancellation.isCancelled) {
        return _defer(claimed, normalized, PaymentSyncOutcome.cancelled, recovered.length);
      }
      final Set<String> acknowledged = response.acknowledgedIdempotencyKeys.toSet();
      int appliedAcks = 0;
      int deferred = 0;
      for (final PaymentOutboxItem item in claimed) {
        if (acknowledged.contains(item.envelope.idempotencyKey)) {
          await outbox.acknowledge(item);
          appliedAcks++;
        } else {
          await outbox.fail(
            item,
            normalized,
            reason: 'partial_ack',
            retryAfter: response.retryAfter,
          );
          deferred++;
        }
      }
      return PaymentSyncRun(
        outcome: deferred == 0 ? PaymentSyncOutcome.completed : PaymentSyncOutcome.partial,
        recovered: recovered.length,
        claimed: claimed.length,
        acknowledged: appliedAcks,
        deferred: deferred,
      );
    } on PaymentSyncUnavailable {
      return _defer(claimed, normalized, PaymentSyncOutcome.offline, recovered.length);
    }
  }

  Future<PaymentSyncRun> _defer(
    List<PaymentOutboxItem> claimed,
    DateTime now,
    PaymentSyncOutcome outcome,
    int recovered,
  ) async {
    for (final PaymentOutboxItem item in claimed) {
      await outbox.fail(item, now, reason: outcome.name);
    }
    return PaymentSyncRun(
      outcome: outcome,
      recovered: recovered,
      claimed: claimed.length,
      acknowledged: 0,
      deferred: claimed.length,
    );
  }

  PaymentSyncRun _run(PaymentSyncOutcome outcome, {int recovered = 0}) => PaymentSyncRun(
    outcome: outcome,
    recovered: recovered,
    claimed: 0,
    acknowledged: 0,
    deferred: 0,
  );
}
