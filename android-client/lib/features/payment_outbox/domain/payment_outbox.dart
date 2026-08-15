import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

enum PaymentOutboxState { pending, inFlight, acknowledged, failed }

final class OutboxScope {
  const OutboxScope({required this.tenantId, required this.deviceId})
    : assert(tenantId.length >= 3),
      assert(deviceId.length >= 3);

  final String tenantId;
  final String deviceId;

  @override
  bool operator ==(Object other) =>
      other is OutboxScope &&
      other.tenantId == tenantId &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(tenantId, deviceId);
}

/// The local, immutable payment representation. It is not a transport payload.
final class PaymentEnvelope {
  PaymentEnvelope._({
    required this.scope,
    required this.provider,
    required this.providerReference,
    required this.amountMinor,
    required this.currency,
    required this.capturedAt,
    required this.idempotencyKey,
  });

  final OutboxScope scope;
  final String provider;
  final String providerReference;
  final int amountMinor;
  final String currency;
  final DateTime capturedAt;
  final String idempotencyKey;

  static PaymentEnvelope? create({
    required OutboxScope scope,
    required String provider,
    required String providerReference,
    required int amountMinor,
    required String currency,
    required DateTime capturedAt,
  }) {
    if (!RegExp(r'^[A-Z0-9._-]{3,32}$').hasMatch(provider) ||
        !RegExp(r'^[A-Z0-9-]{4,64}$').hasMatch(providerReference) ||
        amountMinor <= 0 ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      return null;
    }
    final DateTime normalized = capturedAt.toUtc();
    final String canonical = <String>[
      scope.tenantId,
      scope.deviceId,
      provider,
      providerReference,
      amountMinor.toString(),
      currency,
      normalized.toIso8601String(),
    ].map((String value) => '${utf8.encode(value).length}:$value').join('|');
    return PaymentEnvelope._(
      scope: scope,
      provider: provider,
      providerReference: providerReference,
      amountMinor: amountMinor,
      currency: currency,
      capturedAt: normalized,
      idempotencyKey: sha256.convert(utf8.encode(canonical)).toString(),
    );
  }

  Map<String, Object> toMap() => UnmodifiableMapView<String, Object>(
    <String, Object>{
      'provider': provider,
      'provider_reference': providerReference,
      'amount_minor': amountMinor,
      'currency': currency,
      'captured_at': capturedAt.toIso8601String(),
      'idempotency_key': idempotencyKey,
    },
  );
}

final class PaymentOutboxItem {
  const PaymentOutboxItem({
    required this.envelope,
    required this.state,
    required this.attempts,
    required this.createdAt,
    this.nextAttemptAt,
    this.lastFailure,
  });

  final PaymentEnvelope envelope;
  final PaymentOutboxState state;
  final int attempts;
  final DateTime createdAt;
  final DateTime? nextAttemptAt;
  final String? lastFailure;
  OutboxScope get scope => envelope.scope;

  PaymentOutboxItem copy({
    PaymentOutboxState? state,
    int? attempts,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    String? lastFailure,
    bool clearLastFailure = false,
  }) => PaymentOutboxItem(
    envelope: envelope,
    state: state ?? this.state,
    attempts: attempts ?? this.attempts,
    createdAt: createdAt,
    nextAttemptAt: clearNextAttemptAt ? null : nextAttemptAt ?? this.nextAttemptAt,
    lastFailure: clearLastFailure ? null : lastFailure ?? this.lastFailure,
  );
}

abstract interface class PaymentOutboxRepository {
  Future<PaymentOutboxItem> putIfAbsent(PaymentOutboxItem item);
  Future<PaymentOutboxItem?> find(OutboxScope scope, String idempotencyKey);
  Future<List<PaymentOutboxItem>> list(OutboxScope scope);
  Future<bool> replace(
    PaymentOutboxItem item, {
    required PaymentOutboxState expectedState,
  });
}

final class PaymentOutbox {
  PaymentOutbox(this.repository, {this.maxAttempts = 5})
    : assert(maxAttempts > 0 && maxAttempts <= 10);

  final PaymentOutboxRepository repository;
  final int maxAttempts;

  Future<PaymentOutboxItem> enqueue(PaymentEnvelope envelope) =>
      repository.putIfAbsent(PaymentOutboxItem(
        envelope: envelope,
        state: PaymentOutboxState.pending,
        attempts: 0,
        createdAt: envelope.capturedAt,
      ));

  Future<List<PaymentOutboxItem>> recover(OutboxScope scope, DateTime now) async {
    final List<PaymentOutboxItem> recovered = <PaymentOutboxItem>[];
    for (final PaymentOutboxItem item in await repository.list(scope)) {
      if (item.state != PaymentOutboxState.inFlight) continue;
      final PaymentOutboxItem pending = item.copy(
        state: PaymentOutboxState.pending,
        nextAttemptAt: now.toUtc(),
        clearLastFailure: true,
      );
      if (await repository.replace(pending, expectedState: PaymentOutboxState.inFlight)) {
        recovered.add(pending);
      }
    }
    return List<PaymentOutboxItem>.unmodifiable(recovered);
  }

  Future<PaymentOutboxItem?> claimNext(OutboxScope scope, DateTime now) async {
    final DateTime normalized = now.toUtc();
    for (final PaymentOutboxItem item in await repository.list(scope)) {
      if (!_eligible(item, normalized)) continue;
      final PaymentOutboxItem claim = item.copy(
        state: PaymentOutboxState.inFlight,
        clearNextAttemptAt: true,
      );
      if (await repository.replace(claim, expectedState: item.state)) return claim;
    }
    return null;
  }

  Future<PaymentOutboxItem> acknowledge(PaymentOutboxItem inFlight) async {
    _requireInFlight(inFlight);
    final PaymentOutboxItem acknowledged = inFlight.copy(
      state: PaymentOutboxState.acknowledged,
      clearNextAttemptAt: true,
      clearLastFailure: true,
    );
    if (!await repository.replace(
      acknowledged,
      expectedState: PaymentOutboxState.inFlight,
    )) {
      throw StateError('outbox transition rejected');
    }
    return acknowledged;
  }

  Future<PaymentOutboxItem> fail(
    PaymentOutboxItem inFlight,
    DateTime now, {
    required String reason,
    Duration? retryAfter,
  }) async {
    _requireInFlight(inFlight);
    if (!RegExp(r'^[a-z0-9_]{3,64}$').hasMatch(reason)) {
      throw ArgumentError.value(reason, 'reason');
    }
    final int attempts = inFlight.attempts + 1;
    final bool retryable = attempts < maxAttempts;
    final Duration delay = retryAfter == null
        ? _backoff(attempts)
        : _boundedRetryAfter(retryAfter);
    final PaymentOutboxItem failed = inFlight.copy(
      state: PaymentOutboxState.failed,
      attempts: attempts,
      nextAttemptAt: retryable ? now.toUtc().add(delay) : null,
      clearNextAttemptAt: !retryable,
      lastFailure: reason,
    );
    if (!await repository.replace(failed, expectedState: PaymentOutboxState.inFlight)) {
      throw StateError('outbox transition rejected');
    }
    return failed;
  }

  bool _eligible(PaymentOutboxItem item, DateTime now) =>
      item.state == PaymentOutboxState.pending ||
      (item.state == PaymentOutboxState.failed &&
          item.attempts < maxAttempts &&
          item.nextAttemptAt != null &&
          !item.nextAttemptAt!.isAfter(now));

  Duration _backoff(int attempt) => Duration(minutes: 1 << (attempt - 1));

  Duration _boundedRetryAfter(Duration retryAfter) {
    if (retryAfter <= Duration.zero) return _backoff(1);
    const Duration maximum = Duration(hours: 24);
    return retryAfter > maximum ? maximum : retryAfter;
  }

  void _requireInFlight(PaymentOutboxItem item) {
    if (item.state != PaymentOutboxState.inFlight) {
      throw StateError('outbox item is not in flight');
    }
  }
}
