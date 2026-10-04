import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/data/encrypted_sms_release_store.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_deposit_http_transport.dart';
import 'package:opencongopay/features/deposit_sync/domain/signed_sms_deposit_parser.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_runtime.dart';
import 'package:opencongopay/features/deposit_sync/presentation/sms_deposit_coordinator.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_bloc.dart';
import 'package:opencongopay/features/payment_outbox/data/sqlite_payment_outbox_repository.dart';
import 'package:opencongopay/features/sms_gateway/domain/sms_gateway.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final DateTime _now = DateTime.utc(2026, 10, 5, 10);
const String _template = 'Received {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}';
const String _installation = '123e4567-e89b-12d3-a456-426614174000';
const String _server = 'https://pairing.example.test';
final String _binding = sha256.convert(utf8.encode('$_installation\n$_server')).toString();

final class _Trust implements PairingQrTrustStore {
  _Trust(this.fingerprint);
  final String fingerprint;
  @override
  Future<PairingQrPinState> lookup(String value) async => value == fingerprint
      ? const PairingQrPinState.matching() : const PairingQrPinState.conflict();
  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String value) => throw StateError('must not pin a release key');
}

final class _Cipher implements PaymentOutboxCipher {
  _Cipher([this.order]);
  final List<String>? order;
  bool failDeposits = false;
  final Map<String, String> cleartexts = <String, String>{};
  @override
  Future<String> encrypt({required String identity, required String cleartext}) async {
    if (cleartext.contains('customer_lookup_identifier')) {
      if (failDeposits) throw StateError('storage failure');
      order?.add('stage');
    }
    final String ciphertext = sha256.convert(utf8.encode('$identity/$cleartext')).toString();
    cleartexts['$identity/$ciphertext'] = cleartext;
    return ciphertext;
  }
  @override
  Future<String> decrypt({required String identity, required String ciphertext}) async => cleartexts['$identity/$ciphertext']!;
}

final class _Location implements PaymentOutboxStorageLocation {
  _Location(this.path);
  final String path;
  @override
  Future<String> directory() async => path;
}

final class _Gateway implements SmsGatewayPort {
  final List<NativeSmsRecord> records = <NativeSmsRecord>[];
  final List<String> trusted = <String>['ORANGE'];
  final List<String> order;
  bool failCommit = false;
  _Gateway(this.order);
  @override
  Future<NativeCaptureHealth> captureHealth() async => const NativeCaptureHealth(fault: null);
  @override
  Future<List<String>> listTrustedSenders() async => List<String>.of(trusted);
  @override
  Future<List<NativeSmsRecord>> drainInbox() async => List<NativeSmsRecord>.of(records);
  @override
  Future<void> commitInboxDecision(String id, NativeCaptureDecision decision) async {
    expect(decision, NativeCaptureDecision.processed);
    order.add('native_commit');
    if (failCommit) throw StateError('storage failure');
    records.removeWhere((NativeSmsRecord record) => record.id == id);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Http implements MobileDepositHttpPort {
  _Http(this.order);
  final List<String> order;
  final List<MobileDepositHttpRequest> requests = <MobileDepositHttpRequest>[];
  bool offline = true;
  @override
  MobileDepositHttpExchange post(MobileDepositHttpRequest request) {
    order.add('http');
    requests.add(request);
    return _Exchange(offline);
  }
}

final class _Exchange implements MobileDepositHttpExchange {
  _Exchange(this.offline);
  final bool offline;
  @override
  Future<MobileDepositHttpResponse> get response async {
    if (offline) throw const DepositTransportUnavailable();
    return MobileDepositHttpResponse(status: 200, body: utf8.encode(
      jsonEncode(<String, Object>{'version': 1, 'nonce': 'response-nonce', 'ciphertext': 'response-ciphertext'})));
  }
  @override
  void abort() {}
}

NativeSmsRecord _sms({String? body, String sender = 'ORANGE'}) => NativeSmsRecord(
  id: List<String>.filled(43, 'A').join(), sender: sender, receivedAt: _now,
  segments: 1, body: body ?? 'Received 125.50 CDF; ref REF-1234; customer customer-private-001; at 2026-10-05T09:59:00Z');

Future<({String bundle, SignedSmsDepositReleaseVerifier verifier})> _signed({
  int version = 1, String template = _template, String expires = '2026-10-06T10:00:00Z',
}) async {
  final SimpleKeyPair key = await Ed25519().newKeyPairFromSeed(List<int>.generate(32, (int i) => i));
  final SimplePublicKey public = await key.extractPublicKey();
  final Map<String, dynamic> release = <String, dynamic>{
    'schema_version': 2, 'provider': 'ORANGE', 'sender': 'ORANGE', 'template': template,
    'pattern_version': version, 'approved_at': '2026-10-04T10:00:00Z', 'expires_at': expires,
  };
  final Signature signature = await Ed25519().sign(SignedSmsDepositReleaseVerifier.canonicalPayload(release), keyPair: key);
  release['signature'] = base64UrlEncode(signature.bytes).replaceAll('=', '');
  return (bundle: jsonEncode(<String, Object>{'signing_public_key': base64UrlEncode(public.bytes).replaceAll('=', ''),
    'release': release}), verifier: SignedSmsDepositReleaseVerifier(
      _Trust(base64UrlEncode(sha256.convert(public.bytes).bytes).replaceAll('=', ''))));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  const MethodChannel channel = MethodChannel('openpaycongo/mobile_envelope');
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('signed captured SMS stages ciphertext before native decision and replays unchanged after restart', () async {
    final signed = await _signed();
    final Directory directory = await Directory.systemTemp.createTemp('sms-pipeline-');
    final List<String> order = <String>[];
    final _Cipher cipher = _Cipher(order);
    final _Location location = _Location(directory.path);
    final _Gateway gateway = _Gateway(order)..records.add(_sms());
    final _Http http = _Http(order);
    final List<Map<String, dynamic>> sealed = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'journalBinding') return _binding;
      if (call.method == 'seal') {
        final Map<Object?, Object?> args = call.arguments as Map<Object?, Object?>;
        expect(args['operation'], 'sms_deposit');
        sealed.add(jsonDecode(utf8.decode(args['payload'] as Uint8List)) as Map<String, dynamic>);
        order.add('seal');
        return <String, Object>{'version': 1, 'server_base_url': _server, 'installation_id': _installation,
          'counter': '${sealed.length}', 'nonce': 'request-nonce', 'ciphertext': 'opaque-request-ciphertext'};
      }
      expect(call.method, 'open');
      return 'replayed';
    });
    EncryptedSmsReleaseStore releases = await EncryptedSmsReleaseStore.open(verifier: signed.verifier, cipher: cipher, location: location);
    DepositSubmissionRuntime runtime = await DepositSubmissionRuntime.createPairedMobileEnvelope(http: http, cipher: cipher, location: location);
    SmsDepositCoordinator coordinator = SmsDepositCoordinator(gateway: gateway, releases: releases, submissions: runtime.bloc, now: () => _now);
    expect(await coordinator.installRelease(signed.bundle), isTrue);
    await pumpEventQueue();
    expect(order.take(4), <String>['stage', 'native_commit', 'seal', 'http']);
    expect(gateway.records, isEmpty);
    expect(runtime.bloc.state, isA<DepositSubmissionRetryableFailure>());
    expect(sealed.single['amount_minor'], 12550);
    expect(sealed.single['provider_occurred_at'], '2026-10-05T09:59:00Z');
    final Map<String, dynamic> evidence = sealed.single['parser_evidence'] as Map<String, dynamic>;
    expect(evidence['kind'], 'signed_release');
    expect(evidence['evidence_digest'], sha256.convert(utf8.encode(_sms().body)).toString());
    for (final MobileDepositHttpRequest request in http.requests) {
      expect(utf8.decode(request.body), isNot(contains('customer-private-001')));
      expect(utf8.decode(request.body), isNot(contains(_sms().body)));
    }
    await coordinator.close(); await runtime.close(); await releases.close();
    final String raw = String.fromCharCodes(await File(join(directory.path, 'opencongopay-deposit-$_binding.db')).readAsBytes());
    expect(raw, isNot(contains('customer-private-001')));
    expect(raw, isNot(contains('REF-1234')));
    http.offline = false;
    releases = await EncryptedSmsReleaseStore.open(verifier: signed.verifier, cipher: cipher, location: location);
    expect(await releases.current(_now), hasLength(1));
    runtime = await DepositSubmissionRuntime.createPairedMobileEnvelope(http: http, cipher: cipher, location: location);
    expect(runtime.bloc.state, isA<DepositSubmissionReplayed>());
    expect(sealed, hasLength(2));
    expect(sealed[1], sealed[0]);
    gateway.records.add(NativeSmsRecord(id: List<String>.filled(43, 'B').join(),
      sender: 'ORANGE', receivedAt: _now.add(const Duration(seconds: 1)), segments: 1, body: _sms().body));
    coordinator = SmsDepositCoordinator(gateway: gateway, releases: releases, submissions: runtime.bloc, now: () => _now);
    await coordinator.sync(); await pumpEventQueue();
    expect(gateway.records, isEmpty);
    expect(sealed, hasLength(2), reason: 'acknowledged duplicate capture never generates a new financial request');
    await coordinator.close(); await runtime.close(); await releases.close(); await directory.delete(recursive: true);
  });

  test('rejects wrong authority, legacy fields, expired release, ambiguous money and invalid provider dates', () async {
    final signed = await _signed();
    final SignedSmsDepositRelease? release = await signed.verifier.verify(signed.bundle, _now);
    expect(release, isNotNull);
    expect(await SignedSmsDepositReleaseVerifier(_Trust('other')).verify(signed.bundle, _now), isNull);
    final legacy = await _signed(template: '{amount} {currency} {reference}');
    expect(await legacy.verifier.verify(legacy.bundle, _now), isNull);
    final expired = await _signed(expires: '2026-10-05T09:00:00Z');
    expect(await expired.verifier.verify(expired.bundle, _now), isNull);
    final Map<String, dynamic> tampered = jsonDecode(signed.bundle) as Map<String, dynamic>;
    (tampered['release'] as Map<String, dynamic>)['provider'] = 'AIRTEL';
    expect(await signed.verifier.verify(jsonEncode(tampered), _now), isNull);
    const SignedSmsDepositParser parser = SignedSmsDepositParser();
    for (final String body in <String>[
      _sms().body.replaceFirst('125.50', '125,50'), _sms().body.replaceFirst('CDF', 'USD'),
      _sms().body.replaceFirst('2026-10-05', '2026-02-30'), _sms().body.replaceFirst('09:59:00Z', '09:59:00'),
    ]) { expect(parser.parse(_sms(body: body), release!, _now), isNull); }
    expect(parser.parse(_sms(sender: 'AIRTEL'), release!, _now), isNull);
  });

  test('encrypted release authority prevents rollback after expiration and conflicting same-version installs', () async {
    final first = await _signed(version: 2);
    final lower = await _signed();
    final changed = await _signed(version: 2, template: 'Transfer {amount} {currency}; ref {reference}; customer {customer}; at {occurred_at}');
    final Directory directory = await Directory.systemTemp.createTemp('sms-release-');
    final EncryptedSmsReleaseStore store = await EncryptedSmsReleaseStore.open(
      verifier: first.verifier, cipher: _Cipher(), location: _Location(directory.path));
    expect(await store.install(first.bundle, _now), isTrue);
    expect(await store.install(lower.bundle, _now), isFalse);
    expect(await store.install(changed.bundle, _now), isFalse);
    expect(await store.current(DateTime.utc(2026, 10, 7)), isEmpty);
    await store.close(); await directory.delete(recursive: true);
  });

  test('journal failure prevents raw acknowledgement and transport; revoked sender leaves evidence pending', () async {
    final signed = await _signed();
    final Directory directory = await Directory.systemTemp.createTemp('sms-stage-failure-');
    final _Cipher cipher = _Cipher()..failDeposits = true;
    final _Location location = _Location(directory.path);
    final List<String> order = <String>[];
    final _Gateway gateway = _Gateway(order)..records.add(_sms());
    final _Http http = _Http(order);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (MethodCall call) async { expect(call.method, 'journalBinding'); return _binding; });
    final EncryptedSmsReleaseStore releases = await EncryptedSmsReleaseStore.open(
      verifier: signed.verifier, cipher: cipher, location: location);
    final DepositSubmissionRuntime runtime = await DepositSubmissionRuntime.createPairedMobileEnvelope(
      http: http, cipher: cipher, location: location);
    final SmsDepositCoordinator coordinator = SmsDepositCoordinator(
      gateway: gateway, releases: releases, submissions: runtime.bloc, now: () => _now);
    expect(await coordinator.installRelease(signed.bundle), isTrue);
    expect(coordinator.state, SmsDepositSyncStatus.storageUnavailable);
    expect(gateway.records, hasLength(1)); expect(order, isEmpty); expect(http.requests, isEmpty);
    cipher.failDeposits = false;
    gateway.trusted.clear();
    await coordinator.sync(); await pumpEventQueue();
    expect(coordinator.state, SmsDepositSyncStatus.reviewRequired);
    expect(gateway.records, hasLength(1)); expect(order, isEmpty);
    await coordinator.close(); await runtime.close(); await releases.close(); await directory.delete(recursive: true);
  });
}
