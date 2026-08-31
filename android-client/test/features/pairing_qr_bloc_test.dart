import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_bloc.dart';

void main() {
  test(
    'accepts current signed QR only with matching pinned fingerprint',
    () async {
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: _MatchingPinStore(),
        now: () => DateTime.utc(2026, 8, 10, 9, 31, 59),
      );
      final Future<PairingQrState> result = bloc.stream.first;

      bloc.add(const PairingQrScanned(_signedQr));

      final PairingQrAccepted accepted = (await result) as PairingQrAccepted;
      expect(accepted.trustMode, PairingQrTrustMode.pinnedContinuity);
      expect(accepted.toString(), isNot(contains(_signedQr)));
      await bloc.close();
    },
  );

  test('rejects every signed QR field mutation', () async {
    for (final MapEntry<String, String> mutation in <MapEntry<String, String>>[
      const MapEntry<String, String>('version', '2'),
      const MapEntry<String, String>(
        'endpoint',
        'https://other.example.test/v1/pairing/complete',
      ),
      const MapEntry<String, String>('intent_id', 'AQECAwQFBgcICQoLDA0ODw'),
      const MapEntry<String, String>(
        'intent_nonce',
        'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      ),
      const MapEntry<String, String>('expires_at', '2026-08-10T09:32:01Z'),
      const MapEntry<String, String>(
        'algorithms',
        'X25519-HKDF-SHA256-AES-256-GCM',
      ),
      const MapEntry<String, String>(
        'enrollment_signing_fingerprint',
        'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      ),
      const MapEntry<String, String>(
        'enrollment_signing_public_key',
        'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      ),
      const MapEntry<String, String>(
        'server_key_agreement_public_key',
        'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      ),
      const MapEntry<String, String>('trust_mode', 'first_use_requires_sas'),
    ]) {
      final Map<String, Object?> value =
          jsonDecode(_signedQr) as Map<String, Object?>;
      value[mutation.key] = mutation.value;
      final PairingQrState state = await _scan(
        jsonEncode(value),
        _MatchingPinStore(),
        now: DateTime.utc(2026, 8, 10, 9, 31, 59),
      );
      expect(state, isA<PairingQrRejected>(), reason: mutation.key);
    }
  });

  test('rejects a fingerprint mismatch before trust lookup', () async {
    final Map<String, Object?> value =
        jsonDecode(_signedQr) as Map<String, Object?>;
    value['enrollment_signing_fingerprint'] =
        'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
    final _CountingStore store = _CountingStore(
      const PairingQrPinState.matching(),
    );

    expect(
      await _scan(
        jsonEncode(value),
        store,
        now: DateTime.utc(2026, 8, 10, 9, 31, 59),
      ),
      isA<PairingQrRejected>(),
    );
    expect(store.lookups, 0);
  });

  test('treats exact expiry as expired before trust lookup', () async {
    final _CountingStore store = _CountingStore(
      const PairingQrPinState.matching(),
    );

    final PairingQrState state = await _scan(
      _signedQr,
      store,
      now: DateTime.utc(2026, 8, 10, 9, 32),
    );

    expect((state as PairingQrRejected).reason, PairingQrRejection.expired);
    expect(store.lookups, 0);
  });

  test('validator-only flow rejects signed first use', () async {
    final String qr = await _firstUseQr();

    expect(await _scan(qr, const _NoPinStore()), isA<PairingQrRejected>());
  });

  test(
    'rejects pin conflict and fails closed when trust lookup fails',
    () async {
      expect(
        await _scan(
          _signedQr,
          const _ConflictStore(),
          now: DateTime.utc(2026, 8, 10, 9, 31, 59),
        ),
        isA<PairingQrRejected>(),
      );
      final PairingQrState unavailable = await _scan(
        _signedQr,
        const _FailingStore(),
        now: DateTime.utc(2026, 8, 10, 9, 31, 59),
      );
      expect(
        (unavailable as PairingQrRejected).reason,
        PairingQrRejection.trustUnavailable,
      );
    },
  );

  test('rejects endpoint grammar and non-canonical base64url', () async {
    final Map<String, Object?> endpoint =
        jsonDecode(_signedQr) as Map<String, Object?>;
    endpoint['endpoint'] =
        'https://pairing.example.test/v1/pairing/complete?token=no';
    final Map<String, Object?> encoding =
        jsonDecode(_signedQr) as Map<String, Object?>;
    encoding['intent_id'] = 'AAECAwQFBgcICQoLDA0OD!';

    expect(
      await _scan(jsonEncode(endpoint), _MatchingPinStore()),
      isA<PairingQrRejected>(),
    );
    expect(
      await _scan(jsonEncode(encoding), _MatchingPinStore()),
      isA<PairingQrRejected>(),
    );
  });

  test('fails closed for a structurally valid invalid Ed25519 key', () async {
    final Map<String, Object?> value =
        jsonDecode(_signedQr) as Map<String, Object?>;
    final List<int> invalidKey = List<int>.filled(32, 0xff);
    value['enrollment_signing_public_key'] = _b64(invalidKey);
    value['enrollment_signing_fingerprint'] = _b64(
      sha256.convert(invalidKey).bytes,
    );

    expect(
      await _scan(jsonEncode(value), const _NoPinStore()),
      isA<PairingQrRejected>(),
    );
  });
}

Future<PairingQrState> _scan(
  String value,
  PairingQrTrustStore store, {
  DateTime? now,
}) async {
  final PairingQrBloc bloc = PairingQrBloc(
    trustStore: store,
    now: () => now ?? DateTime.utc(2026, 8, 10, 9, 31, 59),
  );
  final Future<PairingQrState> result = bloc.stream.first;
  bloc.add(PairingQrScanned(value));
  final PairingQrState state = await result;
  await bloc.close();
  return state;
}

Future<String> _firstUseQr() async {
  final Ed25519 algorithm = Ed25519();
  final KeyPair keyPair = await algorithm.newKeyPair();
  final SimplePublicKey publicKey =
      await keyPair.extractPublicKey() as SimplePublicKey;
  final Map<String, String> value = <String, String>{
    'version': '1',
    'endpoint': 'https://pairing.example.test/v1/pairing/complete',
    'intent_id': _b64(List<int>.generate(16, (int index) => index)),
    'intent_nonce': _b64(List<int>.generate(32, (int index) => index + 16)),
    'expires_at': '2026-08-10T09:32:00Z',
    'algorithms': 'X25519-HKDF-SHA256-AES-256-GCM+Ed25519',
    'enrollment_signing_public_key': _b64(publicKey.bytes),
    'server_key_agreement_public_key': _b64(
      List<int>.generate(32, (int index) => index + 48),
    ),
    'trust_mode': 'first_use_requires_sas',
  };
  value['enrollment_signing_fingerprint'] = _b64(
    sha256.convert(publicKey.bytes).bytes,
  );
  final Signature signature = await algorithm.sign(
    _transcript(value),
    keyPair: keyPair,
  );
  value['signature'] = _b64(signature.bytes);
  return jsonEncode(value);
}

Uint8List _transcript(Map<String, String> value) {
  final BytesBuilder result = BytesBuilder(copy: false);
  for (final List<int> field in <List<int>>[
    utf8.encode('openpaycongo/pairing/qr'),
    utf8.encode(value['version']!),
    utf8.encode(value['endpoint']!),
    base64Url.decode(base64Url.normalize(value['intent_id']!)),
    base64Url.decode(base64Url.normalize(value['intent_nonce']!)),
    utf8.encode(value['expires_at']!),
    utf8.encode(value['algorithms']!),
    base64Url.decode(
      base64Url.normalize(value['enrollment_signing_public_key']!),
    ),
    base64Url.decode(
      base64Url.normalize(value['enrollment_signing_fingerprint']!),
    ),
    base64Url.decode(
      base64Url.normalize(value['server_key_agreement_public_key']!),
    ),
    utf8.encode(value['trust_mode']!),
  ]) {
    result.add(<int>[field.length >> 8, field.length & 0xff]);
    result.add(field);
  }
  return result.toBytes();
}

String _b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

const String _signedQr = '''
{"version":"1","endpoint":"https://pairing.example.test/v1/pairing/complete","intent_id":"AAECAwQFBgcICQoLDA0ODw","intent_nonce":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8","expires_at":"2026-08-10T09:32:00Z","algorithms":"X25519-HKDF-SHA256-AES-256-GCM+Ed25519","enrollment_signing_fingerprint":"Fs81cR1vRgNPZbGmGrwneKW5Th0PkADWm8jyzB6fhI0","enrollment_signing_public_key":"Q3o0tdFSDnY9xtFPrWsm-F7fh-yGnYnPRrkJfZ99vRU","server_key_agreement_public_key":"QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8","signature":"3Gd5-vj0Lyh7dKP8j3Au8_dmWa8vwXtYmG9FL7yi1gQfAqBGEYHnzAmtTeyeHoolFXszu2STWxMKBLTLKhPqBg","trust_mode":"pinned_continuity"}
''';

final class _MatchingPinStore implements PairingQrTrustStore {
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.matching();
}

final class _CountingStore implements PairingQrTrustStore {
  _CountingStore(this.result);
  final PairingQrPinState result;
  int lookups = 0;
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async {
    lookups++;
    return result;
  }
}

final class _NoPinStore implements PairingQrTrustStore {
  const _NoPinStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.none();
}

final class _ConflictStore implements PairingQrTrustStore {
  const _ConflictStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.conflict();
}

final class _FailingStore implements PairingQrTrustStore {
  const _FailingStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      throw StateError('secure store unavailable');
}
