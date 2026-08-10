import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/sms_gateway.dart';

final class PlatformSmsGateway implements SmsGatewayPort {
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _senderPattern = RegExp(
    r'^(?:\+[1-9][0-9]{7,14}|[A-Z0-9]{3,11})$',
  );
  static final RegExp _cursorPattern = RegExp(r'^v3:[0-9]{1,10}:[0-9]{1,2}$');
  static const int _maxEpochMillis = 253402300799999;
  const PlatformSmsGateway([
    this._channel = const MethodChannel('openpaycongo/sms_gateway'),
  ]);
  final MethodChannel _channel;

  @override
  Future<SmsAccessState> permissionState() async =>
      _decode(await _channel.invokeMethod<String>('permissionState'));
  @override
  Future<SmsAccessState> requestPermission() async =>
      _decode(await _channel.invokeMethod<String>('requestPermission'));
  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
  @override
  Future<int> accessGeneration() async {
    final int? generation = await _channel.invokeMethod<int>(
      'accessGeneration',
    );
    if (generation == null || generation < 1) {
      throw const FormatException('invalid_access_generation');
    }
    return generation;
  }
  @override
  Future<void> setUnlocked(bool unlocked, {int? generation}) =>
      _channel.invokeMethod<void>('setUnlocked', <String, Object?>{
        'unlocked': unlocked,
        'generation': generation,
      });
  @override
  Future<List<String>> addTrustedSender(String sender) async {
    if (!_senderPattern.hasMatch(sender)) {
      throw const FormatException('invalid_trusted_sender');
    }
    final List<Object?>? values = await _channel.invokeMethod<List<Object?>>(
      'addTrustedSender',
      sender,
    );
    if (values == null) throw const FormatException('invalid_trusted_senders');
    return _trustedSenders(values);
  }

  @override
  Future<List<String>> listTrustedSenders() async {
    final List<Object?>? values = await _channel.invokeMethod<List<Object?>>(
      'listTrustedSenders',
    );
    if (values == null) {
      throw const FormatException('invalid_trusted_senders');
    }
    return _trustedSenders(values);
  }

  @override
  Future<List<String>> clearTrustedSenders() async {
    final List<Object?>? values = await _channel.invokeMethod<List<Object?>>(
      'clearTrustedSenders',
    );
    if (values == null) throw const FormatException('invalid_trusted_senders');
    return _trustedSenders(values);
  }

  @override
  Future<List<String>> revokeTrustedSender(String sender) async {
    if (!_senderPattern.hasMatch(sender)) {
      throw const FormatException('invalid_trusted_sender');
    }
    final List<Object?>? values = await _channel.invokeMethod<List<Object?>>(
      'revokeTrustedSender',
      sender,
    );
    if (values == null) throw const FormatException('invalid_trusted_senders');
    return _trustedSenders(values);
  }

  @override
  Future<NativeCaptureHealth> captureHealth() async {
    final Map<Object?, Object?>? value = await _channel
        .invokeMethod<Map<Object?, Object?>>('captureHealth');
    if (value == null) {
      throw const FormatException('invalid_capture_health');
    }
    final Object? faultValue = value['fault'];
    final CaptureFault? fault = switch (faultValue) {
      null => null,
      'capacity' => CaptureFault.capacity,
      'storage' => CaptureFault.storage,
      'corruption' => CaptureFault.corruption,
      'keyInvalidated' => CaptureFault.keyInvalidated,
      _ => throw const FormatException('invalid_capture_fault'),
    };
    final Object? missedValue = value['missed'];
    final CaptureMissSignal? missed = switch (missedValue) {
      null => null,
      'overload' => CaptureMissSignal.overload,
      'expired' => CaptureMissSignal.expired,
      _ => throw const FormatException('invalid_capture_miss'),
    };
    final Object? occurred = value['occurred_at_ms'];
    final Object? missedAt = value['missed_at_ms'];
    final Object? decisionCount = value['decision_count'];
    final Object? decisionBytes = value['decision_encrypted_bytes'];
    final Object? recoveryRequired = value['recovery_required'];
    if (!_hasExactKeys(value, const <Object?>{
          'fault',
          'occurred_at_ms',
          'missed',
          'missed_at_ms',
          'decision_count',
          'decision_encrypted_bytes',
          'recovery_required',
        }) ||
        !_validEpoch(occurred) ||
        !_validEpoch(missedAt) ||
        recoveryRequired is! bool ||
        (recoveryRequired
            ? decisionCount != null || decisionBytes != null
            : decisionCount is! int ||
                decisionCount < 0 ||
                decisionBytes is! int ||
                decisionBytes < 0) ||
        (!recoveryRequired && (fault == null) != (occurred == null)) ||
        (recoveryRequired && fault == null && occurred != null) ||
        (missed == null) != (missedAt == null)) {
      throw const FormatException('invalid_capture_health');
    }
    return NativeCaptureHealth(
      fault: fault,
      occurredAt: occurred is int
          ? DateTime.fromMillisecondsSinceEpoch(occurred, isUtc: true)
          : null,
      decisionCount: decisionCount as int?,
      decisionEncryptedBytes: decisionBytes as int?,
      missed: missed,
      missedAt: missedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(missedAt, isUtc: true)
          : null,
      recoveryRequired: recoveryRequired,
    );
  }

  @override
  Future<bool> probeStorage() async {
    final bool? result = await _channel.invokeMethod<bool>('probeStorage');
    if (result == null) throw const FormatException('invalid_storage_probe');
    return result;
  }

  @override
  Future<NativeDecisionPage> exportDecisions({
    int limit = 100,
    String? cursor,
  }) async {
    if (limit < 1 || limit > 100) {
      throw const FormatException('invalid_decision_export_limit');
    }
    if (cursor != null && !_cursorPattern.hasMatch(cursor)) {
      throw const FormatException('invalid_decision_export_cursor');
    }
    final Map<Object?, Object?>? page =
        await _channel.invokeMethod<Map<Object?, Object?>>(
          'exportDecisions',
          <String, Object?>{'limit': limit, 'cursor': cursor},
        );
    if (page == null ||
        !_hasExactKeys(page, const <Object?>{
          'records',
          'next_cursor',
          'truncated',
        })) {
      throw const FormatException('invalid_decision_export');
    }
    final Object? rawValues = page['records'];
    final Object? nextCursor = page['next_cursor'];
    final Object? truncated = page['truncated'];
    if (rawValues is! List<Object?> ||
        nextCursor is! String? ||
        (nextCursor != null && !_cursorPattern.hasMatch(nextCursor)) ||
        truncated is! bool ||
        (truncated != (nextCursor != null))) {
      throw const FormatException('invalid_decision_export');
    }
    final List<Object?> values = rawValues;
    if (values.length > limit ||
        (truncated && values.isEmpty) ||
        (nextCursor != null && nextCursor == cursor)) {
      throw const FormatException('decision_export_too_large');
    }
    final List<NativeDecisionRecord> records = values
        .map(_decodeDecision)
        .toList(growable: false);
    if (records.map((NativeDecisionRecord item) => item.id).toSet().length !=
        records.length) {
      throw const FormatException('invalid_decision_export');
    }
    return NativeDecisionPage(
      records: records,
      nextCursor: nextCursor,
      truncated: truncated,
    );
  }

  @override
  Future<List<NativeSmsRecord>> drainInbox() async {
    final List<Object?>? values = await _channel.invokeMethod<List<Object?>>(
      'drainInbox',
    );
    if (values == null) {
      throw const FormatException('invalid_native_inbox');
    }
    if (values.length > 500) {
      throw const FormatException('inbox_too_large');
    }
    return values.map(_decodeRecord).toList(growable: false);
  }

  @override
  Future<void> commitInboxDecision(String id, NativeCaptureDecision decision) {
    if (!_idPattern.hasMatch(id)) {
      throw const FormatException('invalid_inbox_id');
    }
    return _channel.invokeMethod<void>('commitInboxDecision', <String, String>{
      'id': id,
      'decision': decision.name,
    });
  }

  static SmsAccessState _decode(String? value) => switch (value) {
    'granted' => SmsAccessState.granted,
    'denied' => SmsAccessState.denied,
    'permanently_denied' => SmsAccessState.permanentlyDenied,
    _ => SmsAccessState.unavailable,
  };

  static NativeSmsRecord _decodeRecord(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('invalid_native_record');
    }
    final Object? id = value['id'];
    final Object? sender = value['sender'];
    final Object? received = value['received_at_ms'];
    final Object? segments = value['segments'];
    final Object? body = value['body'];
    if (!_hasExactKeys(value, const <Object?>{
          'id',
          'sender',
          'received_at_ms',
          'segments',
          'body',
        }) ||
        id is! String ||
        !_idPattern.hasMatch(id) ||
        sender is! String ||
        !_senderPattern.hasMatch(sender) ||
        received is! int ||
        !_validEpoch(received) ||
        segments is! int ||
        segments < 1 ||
        segments > 8 ||
        body is! String ||
        body.length > 4096 ||
        utf8.encode(body).length > 4096) {
      throw const FormatException('invalid_native_record');
    }
    return NativeSmsRecord(
      id: id,
      sender: sender,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(received, isUtc: true),
      segments: segments,
      body: body,
    );
  }

  static NativeDecisionRecord _decodeDecision(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('invalid_native_decision');
    }
    final Object? id = value['id'];
    final Object? decisionValue = value['decision'];
    final Object? decidedAt = value['decided_at_ms'];
    final NativeCaptureDecision? decision = switch (decisionValue) {
      'reviewed' => NativeCaptureDecision.reviewed,
      'rejected' => NativeCaptureDecision.rejected,
      'processed' => NativeCaptureDecision.processed,
      _ => null,
    };
    if (!_hasExactKeys(value, const <Object?>{
          'id',
          'decision',
          'decided_at_ms',
        }) ||
        id is! String ||
        !_idPattern.hasMatch(id) ||
        decision == null ||
        decidedAt is! int ||
        !_validEpoch(decidedAt)) {
      throw const FormatException('invalid_native_decision');
    }
    return NativeDecisionRecord(
      id: id,
      decision: decision,
      decidedAt: DateTime.fromMillisecondsSinceEpoch(decidedAt, isUtc: true),
    );
  }

  static List<String> _trustedSenders(List<Object?> values) {
    if (values.length > 64) {
      throw const FormatException('invalid_trusted_senders');
    }
    final List<String> result = <String>[];
    for (final Object? value in values) {
      if (value is! String || !_senderPattern.hasMatch(value)) {
        throw const FormatException('invalid_trusted_sender');
      }
      result.add(value);
    }
    final List<String> canonical = result.toSet().toList()..sort();
    if (canonical.length != result.length ||
        !_sameStrings(result, canonical)) {
      throw const FormatException('invalid_trusted_senders');
    }
    return List<String>.unmodifiable(result);
  }

  static bool _sameStrings(List<String> left, List<String> right) {
    for (int index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _validEpoch(Object? value) =>
      value == null ||
      (value is int && value >= 0 && value <= _maxEpochMillis);

  static bool _hasExactKeys(
    Map<Object?, Object?> value,
    Set<Object?> expected,
  ) =>
      value.length == expected.length && value.keys.every(expected.contains);
}
