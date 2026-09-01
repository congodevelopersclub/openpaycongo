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
        now: () => DateTime.utc(2026, 9, 1, 11, 59, 59),
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
      const MapEntry<String, String>('version', '1'),
      const MapEntry<String, String>(
        'endpoint',
        'https://other.example.test/v1/pairing/complete',
      ),
      const MapEntry<String, String>('intent_id', 'AQECAwQFBgcICQoLDA0ODw'),
      const MapEntry<String, String>(
        'intent_nonce',
        'AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      ),
      const MapEntry<String, String>('expires_at', '2026-09-01T12:00:01Z'),
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
      const MapEntry<String, String>(
        'pairing_secret',
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
        now: DateTime.utc(2026, 9, 1, 11, 59, 59),
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
        now: DateTime.utc(2026, 9, 1, 11, 59, 59),
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
      now: DateTime.utc(2026, 9, 1, 12),
    );

    expect((state as PairingQrRejected).reason, PairingQrRejection.expired);
    expect(store.lookups, 0);
  });

  test(
    'first use starts only provisional SAS flow without pin persistence',
    () async {
      final String qr = await _firstUseQr();
      final _FirstUseStore store = _FirstUseStore();
      final _RecordingCredentialSink sink = _RecordingCredentialSink();
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: store,
        credentialSink: sink,
        now: () => DateTime.utc(2026, 8, 10, 9, 31, 59),
      );
      final Future<PairingQrState> result = bloc.stream.first;

      bloc.add(PairingQrScanned(qr));

      final PairingQrAccepted state = await result as PairingQrAccepted;
      expect(state.trustMode, PairingQrTrustMode.firstUseRequiresSas);
      expect(sink.receivedExpectedMaterial, isTrue);
      expect(store.persistCalls, 0);
      await bloc.close();
    },
  );

  test(
    'hands typed credential to pairing infrastructure, never BLoC state',
    () async {
      final _RecordingCredentialSink sink = _RecordingCredentialSink();
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: _MatchingPinStore(),
        credentialSink: sink,
        now: () => DateTime.utc(2026, 9, 1, 11, 59, 59),
      );
      final Future<PairingQrState> result = bloc.stream.first;

      bloc.add(const PairingQrScanned(_signedQr));

      final PairingQrState state = await result;
      expect(state, isA<PairingQrAccepted>());
      expect(
        state.toString(),
        isNot(contains('QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8')),
      );
      expect(sink.credential, isA<PairingQrCompletionCredential>());
      expect(sink.credential!.materialize, throwsA(isA<StateError>()));
      expect(sink.receivedExpectedMaterial, isTrue);
      final PairingQrCompletionMaterial material = sink.material!;
      expect(material.intentId, everyElement(0));
      expect(material.serverKeyAgreementPublicKey, everyElement(0));
      expect(material.pairingSecret, everyElement(0));
      await bloc.close();
    },
  );

  test(
    'wipes credential when pairing infrastructure rejects handoff',
    () async {
      final _FailingCredentialSink sink = _FailingCredentialSink();
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: _MatchingPinStore(),
        credentialSink: sink,
        now: () => DateTime.utc(2026, 9, 1, 11, 59, 59),
      );
      final Future<PairingQrState> result = bloc.stream.first;

      bloc.add(const PairingQrScanned(_signedQr));

      expect(await result, isA<PairingQrRejected>());
      expect(sink.credential, isA<PairingQrCompletionCredential>());
      expect(sink.credential!.materialize, throwsA(isA<StateError>()));
      await bloc.close();
    },
  );

  test(
    'rejects pin conflict and fails closed when trust lookup fails',
    () async {
      expect(
        await _scan(
          _signedQr,
          const _ConflictStore(),
          now: DateTime.utc(2026, 9, 1, 11, 59, 59),
        ),
        isA<PairingQrRejected>(),
      );
      final PairingQrState unavailable = await _scan(
        _signedQr,
        const _FailingStore(),
        now: DateTime.utc(2026, 9, 1, 11, 59, 59),
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
      now: () => DateTime.utc(2026, 9, 1, 11, 59, 59),
    );
    final List<PairingQrState> states = <PairingQrState>[];
    final Completer<void> accepted = Completer<void>();
    final StreamSubscription<PairingQrState> subscription = bloc.stream.listen((
      PairingQrState state,
    ) {
      states.add(state);
      if (state is PairingQrAccepted && !accepted.isCompleted) {
        accepted.complete();
      }
    });

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

  test('newest scan wipes an older verified QR that completes later', () async {
    final _DelayedFirstVerifier verifier = _DelayedFirstVerifier();
    final PairingQrBloc bloc = PairingQrBloc(
      trustStore: _MatchingPinStore(),
      verifier: verifier,
      now: () => DateTime.utc(2026, 9, 1, 11, 59, 59),
    );
    final List<PairingQrState> states = <PairingQrState>[];
    final Completer<void> accepted = Completer<void>();
    final StreamSubscription<PairingQrState> subscription = bloc.stream.listen((
      PairingQrState state,
    ) {
      states.add(state);
      if (state is PairingQrAccepted && !accepted.isCompleted) {
        accepted.complete();
      }
    });

    bloc.add(const PairingQrScanned(_signedQr));
    await verifier.firstStarted.future;
    bloc.add(const PairingQrScanned(_signedQr));
    await accepted.future;
    await verifier.completeFirst();
    await Future<void>.delayed(Duration.zero);

    expect(states, hasLength(1));
    expect(states.single, isA<PairingQrAccepted>());
    final PairingQrVerification stale = verifier.firstVerification!;
    expect(stale.intentId, everyElement(0));
    expect(stale.serverKeyAgreementPublicKey, everyElement(0));
    expect(stale.pairingSecret, everyElement(0));
    await subscription.cancel();
    await bloc.close();
  });

  test(
    'drops an overlapping scan request without invalidating the first scan',
    () async {
      final _ControlledScanner scanner = _ControlledScanner();
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: _MatchingPinStore(),
        scanner: scanner,
        now: () => DateTime.utc(2026, 9, 1, 11, 59, 59),
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
    },
  );

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

  test(
    'rechecks exact expiry after delayed trust lookup before acceptance',
    () async {
      final _DelayedLookupStore store = _DelayedLookupStore();
      DateTime now = DateTime.utc(2026, 9, 1, 11, 59, 59);
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: store,
        now: () => now,
      );
      final Future<PairingQrState> result = bloc.stream.first;

      bloc.add(const PairingQrScanned(_signedQr));
      await store.lookupStarted.future;
      now = DateTime.utc(2026, 9, 1, 12);
      store.releaseLookup();

      final PairingQrState state = await result;
      expect((state as PairingQrRejected).reason, PairingQrRejection.expired);
      expect(state.toString(), isNot(contains(_signedQr)));
      await bloc.close();
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
    now: () => now ?? DateTime.utc(2026, 9, 1, 11, 59, 59),
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
    'version': '2',
    'endpoint': 'https://pairing.example.test/v1/pairing/complete',
    'intent_id': _b64(List<int>.generate(16, (int index) => index)),
    'intent_nonce': _b64(List<int>.generate(32, (int index) => index + 16)),
    'expires_at': '2026-08-10T09:32:00Z',
    'algorithms': 'X25519-crypto_kx-XChaCha20-Poly1305-IETF',
    'enrollment_signing_public_key': _b64(publicKey.bytes),
    'server_key_agreement_public_key': _b64(
      List<int>.generate(32, (int index) => index + 48),
    ),
    'pairing_secret': _b64(List<int>.generate(32, (int index) => index + 64)),
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
    base64Url.decode(base64Url.normalize(value['pairing_secret']!)),
    utf8.encode(value['trust_mode']!),
  ]) {
    result.add(<int>[field.length >> 8, field.length & 0xff]);
    result.add(field);
  }
  return result.toBytes();
}

String _b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

const String _signedQr = '''
{"version":"2","endpoint":"https://pairing.example.test/v1/pairing/complete","intent_id":"YGFiY2RlZmdoaWprbG1ubw","intent_nonce":"sLGys7S1tre4ubq7vL2-v8DBwsPExcbHyMnKy8zNzs8","expires_at":"2026-09-01T12:00:00Z","algorithms":"X25519-crypto_kx-XChaCha20-Poly1305-IETF","enrollment_signing_fingerprint":"gF0vfOTYfcKmnOVpHQRkUe_y1VPmSLhXDydcnkVEvjc","enrollment_signing_public_key":"bw8O6z-_-SXGbQPhnc5I1e3J_-5RzSaucd055W9_3aI","server_key_agreement_public_key":"DgIWIj8UcUPTJhWpEYnCiMFyjLo8xfn2IbECbgPYMSk","pairing_secret":"QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8","trust_mode":"pinned_continuity","signature":"v4RXXml4R8bpzzJVflH6W29SQ4OVcjM2TmSlBgy-1nzCqBQ-ivUOjhATZhAgxTpXpiQ09ySmlCmoDZDzadOiAA"}
''';

final class _RecordingCredentialSink implements PairingQrCredentialSink {
  PairingQrCompletionCredential? credential;
  PairingQrCompletionMaterial? material;
  var receivedExpectedMaterial = false;

  @override
  Future<void> accept(PairingQrCompletionCredential value) async {
    credential = value;
    final PairingQrCompletionMaterial copied = value.materialize();
    material = copied;
    try {
      receivedExpectedMaterial =
          copied.endpoint ==
              'https://pairing.example.test/v1/pairing/complete' &&
          copied.pairingSecret.length == 32 &&
          copied.pairingSecret.asMap().entries.every(
            (MapEntry<int, int> entry) => entry.value == entry.key + 64,
          );
    } finally {
      copied.dispose();
    }
  }
}

final class _FailingCredentialSink implements PairingQrCredentialSink {
  PairingQrCompletionCredential? credential;

  @override
  Future<void> accept(PairingQrCompletionCredential value) async {
    credential = value;
    throw StateError('Pairing infrastructure unavailable');
  }
}

final class _MatchingPinStore implements PairingQrTrustStore {
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.matching();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.alreadyStored();
}

final class _DelayedFirstVerifier implements PairingQrVerifier {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<PairingQrVerification?> _firstResult =
      Completer<PairingQrVerification?>();
  String? _firstInput;
  PairingQrVerification? firstVerification;

  @override
  Future<PairingQrVerification?> parseAndVerify(String input) {
    if (_firstInput == null) {
      _firstInput = input;
      firstStarted.complete();
      return _firstResult.future;
    }

    return PairingQrVerification.parseAndVerify(input);
  }

  Future<void> completeFirst() async {
    final PairingQrVerification? verification =
        await PairingQrVerification.parseAndVerify(_firstInput!);
    firstVerification = verification;
    _firstResult.complete(verification);
  }
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
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.alreadyStored();
}

final class _NoPinStore implements PairingQrTrustStore {
  const _NoPinStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.none();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.stored();
}

final class _FirstUseStore implements PairingQrTrustStore {
  var persistCalls = 0;

  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.none();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async {
    persistCalls++;
    return const PairingQrPinWrite.stored();
  }
}

final class _ConflictStore implements PairingQrTrustStore {
  const _ConflictStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.conflict();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.conflict();
}

final class _FailingStore implements PairingQrTrustStore {
  const _FailingStore();
  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      throw StateError('secure store unavailable');

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => throw StateError('secure store unavailable');
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
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.alreadyStored();
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
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.alreadyStored();
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
