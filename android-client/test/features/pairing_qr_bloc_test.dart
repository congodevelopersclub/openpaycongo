import 'dart:async';
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

  test('newest scan wins when an older trust lookup completes later', () async {
    final _DelayedFirstLookupStore store = _DelayedFirstLookupStore();
    final PairingQrBloc bloc = PairingQrBloc(
      trustStore: store,
      now: () => DateTime.utc(2026, 8, 10, 9, 31, 59),
    );
    final List<PairingQrState> states = <PairingQrState>[];
    final Completer<void> accepted = Completer<void>();
    final StreamSubscription<PairingQrState> subscription = bloc.stream.listen(
      (PairingQrState state) {
        states.add(state);
        if (state is PairingQrAccepted && !accepted.isCompleted) {
          accepted.complete();
        }
      },
    );

    bloc.add(const PairingQrScanned(_signedQr));
    await store.firstLookupStarted.future;
    bloc.add(const PairingQrScanned(_signedQr));
    await accepted.future;
    store.releaseFirstLookup();
    await Future<void>.delayed(Duration.zero);

    expect(states.whereType<PairingQrAccepted>(), hasLength(1));
    expect(states, hasLength(1));
    await subscription.cancel();
    await bloc.close();
  });

  test('drops an overlapping scan request without invalidating the first scan',
      () async {
    final _ControlledScanner scanner = _ControlledScanner();
    final PairingQrBloc bloc = PairingQrBloc(
      trustStore: _MatchingPinStore(),
      scanner: scanner,
      now: () => DateTime.utc(2026, 8, 10, 9, 31, 59),
    );
    final Future<PairingQrState> result = bloc.stream.firstWhere(
      (PairingQrState state) => state is PairingQrAccepted,
    );

    bloc
      ..add(const PairingQrScanRequested())
      ..add(const PairingQrScanRequested());
    await scanner.started.future;
    scanner.complete(_signedQr);

    expect(await result, isA<PairingQrAccepted>());
    expect(scanner.calls, 1);
    await bloc.close();
  });

  test('scanner cancellation returns the original BLoC to idle', () async {
    final _ControlledScanner scanner = _ControlledScanner();
    final PairingQrBloc bloc = PairingQrBloc(
      trustStore: _MatchingPinStore(),
      scanner: scanner,
    );
    final Future<PairingQrState> result = bloc.stream.firstWhere(
      (PairingQrState state) => state is PairingQrIdle,
    );

    bloc.add(const PairingQrScanRequested());
    await scanner.started.future;
    scanner.complete(null);

    expect(await result, isA<PairingQrIdle>());
    await bloc.close();
  });

  test('rechecks exact expiry after delayed trust lookup before acceptance', () async {
    final _DelayedLookupStore store = _DelayedLookupStore();
    DateTime now = DateTime.utc(2026, 8, 10, 9, 31, 59);
    final PairingQrBloc bloc = PairingQrBloc(trustStore: store, now: () => now);
    final Future<PairingQrState> result = bloc.stream.first;

    bloc.add(const PairingQrScanned(_signedQr));
    await store.lookupStarted.future;
    now = DateTime.utc(2026, 8, 10, 9, 32);
    store.releaseLookup();

    final PairingQrState state = await result;
    expect((state as PairingQrRejected).reason, PairingQrRejection.expired);
    expect(state.toString(), isNot(contains(_signedQr)));
    await bloc.close();
  });

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

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.alreadyStored();
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

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.alreadyStored();
}

final class _NoPinStore implements PairingQrTrustStore {
  const _NoPinStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.none();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.stored();
}

final class _ConflictStore implements PairingQrTrustStore {
  const _ConflictStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.conflict();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.conflict();
}

final class _FailingStore implements PairingQrTrustStore {
  const _FailingStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      throw StateError('secure store unavailable');

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      throw StateError('secure store unavailable');
}

final class _DelayedFirstLookupStore implements PairingQrTrustStore {
  final Completer<void> firstLookupStarted = Completer<void>();
  final Completer<void> _firstLookupRelease = Completer<void>();
  var _lookups = 0;

  @override
  Future<PairingQrPinState> lookup(String fingerprint) async {
    if (_lookups++ == 0) {
      firstLookupStarted.complete();
      await _firstLookupRelease.future;
    }
    return const PairingQrPinState.matching();
  }

  void releaseFirstLookup() => _firstLookupRelease.complete();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.alreadyStored();
}

final class _DelayedLookupStore implements PairingQrTrustStore {
  final Completer<void> lookupStarted = Completer<void>();
  final Completer<void> _lookupRelease = Completer<void>();

  @override
  Future<PairingQrPinState> lookup(String fingerprint) async {
    lookupStarted.complete();
    await _lookupRelease.future;
    return const PairingQrPinState.matching();
  }

  void releaseLookup() => _lookupRelease.complete();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint) async =>
      const PairingQrPinWrite.alreadyStored();
}

final class _ControlledScanner implements PairingQrScanner {
  final Completer<void> started = Completer<void>();
  final Completer<String?> _result = Completer<String?>();
  int calls = 0;

  @override
  Future<String?> scan() {
    calls++;
    started.complete();
    return _result.future;
  }

  void complete(String? value) => _result.complete(value);
}
