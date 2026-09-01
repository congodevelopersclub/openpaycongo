import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum PairingQrTrustMode { firstUseRequiresSas, pinnedContinuity }

sealed class PairingQrPinState {
  const PairingQrPinState();
  const factory PairingQrPinState.none() = PairingQrNoPin;
  const factory PairingQrPinState.matching() = PairingQrMatchingPin;
  const factory PairingQrPinState.conflict() = PairingQrConflictingPin;
}

final class PairingQrNoPin extends PairingQrPinState {
  const PairingQrNoPin();
}

final class PairingQrMatchingPin extends PairingQrPinState {
  const PairingQrMatchingPin();
}

final class PairingQrConflictingPin extends PairingQrPinState {
  const PairingQrConflictingPin();
}

/// Secure-storage port. Lookup must fail instead of treating unavailable state
/// as no existing pin.
abstract interface class PairingQrTrustStore {
  Future<PairingQrPinState> lookup(String fingerprint);

  /// Called only by a later authenticated confirmation flow after its
  /// independently compared SAS and terminal server decision. This QR
  /// validator never calls it.
  Future<PairingQrPinWrite> persistVerifiedFingerprint(String fingerprint);
}

/// Scanner boundary. Its raw result is passed straight to the validator and is
/// never retained in BLoC state.
abstract interface class PairingQrScanner {
  Future<String?> scan();
}

/// Pairing-infrastructure boundary for verified, sensitive QR material.
///
/// BLoC calls this only after QR signature, expiry, trust checks. UI observes
/// [PairingQrAccepted], never credential. Materialize, use, dispose copies
/// before [accept] returns; BLoC disposes credential immediately afterward.
abstract interface class PairingQrCredentialSink {
  Future<void> accept(PairingQrCompletionCredential credential);
}

abstract interface class PairingQrVerifier {
  Future<PairingQrVerification?> parseAndVerify(String input);
}

final class _DefaultPairingQrVerifier implements PairingQrVerifier {
  const _DefaultPairingQrVerifier();

  @override
  Future<PairingQrVerification?> parseAndVerify(String input) =>
      PairingQrVerification.parseAndVerify(input);
}

/// Typed QR handoff. No raw-QR representation.
///
/// Only [PairingQrCredentialSink] receives this. Never log, serialize, retain
/// pairing secret beyond completion flow.
final class PairingQrCompletionCredential {
  PairingQrCompletionCredential._({
    required this.endpoint,
    required Uint8List intentId,
    required Uint8List serverKeyAgreementPublicKey,
    required Uint8List pairingSecret,
  }) : _intentId = Uint8List.fromList(intentId),
       _serverKeyAgreementPublicKey = Uint8List.fromList(
         serverKeyAgreementPublicKey,
       ),
       _pairingSecret = Uint8List.fromList(pairingSecret);

  final String endpoint;
  final Uint8List _intentId;
  final Uint8List _serverKeyAgreementPublicKey;
  final Uint8List _pairingSecret;
  var _disposed = false;

  /// Creates short-lived copies for pairing infrastructure.
  PairingQrCompletionMaterial materialize() {
    if (_disposed) throw StateError('Pairing QR credential has been disposed');
    return PairingQrCompletionMaterial._(
      endpoint: endpoint,
      intentId: _intentId,
      serverKeyAgreementPublicKey: _serverKeyAgreementPublicKey,
      pairingSecret: _pairingSecret,
    );
  }

  /// Wipes material owned by this handoff after [PairingQrCredentialSink].
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wipe(_intentId);
    _wipe(_serverKeyAgreementPublicKey);
    _wipe(_pairingSecret);
  }
}

/// Completion-only sensitive material. Never place in BLoC state or widgets.
final class PairingQrCompletionMaterial {
  PairingQrCompletionMaterial._({
    required this.endpoint,
    required Uint8List intentId,
    required Uint8List serverKeyAgreementPublicKey,
    required Uint8List pairingSecret,
  }) : intentId = Uint8List.fromList(intentId),
       serverKeyAgreementPublicKey = Uint8List.fromList(
         serverKeyAgreementPublicKey,
       ),
       pairingSecret = Uint8List.fromList(pairingSecret);

  final String endpoint;
  final Uint8List intentId;
  final Uint8List serverKeyAgreementPublicKey;
  final Uint8List pairingSecret;

  /// Call when completion exchange finishes or aborts.
  void dispose() {
    _wipe(intentId);
    _wipe(serverKeyAgreementPublicKey);
    _wipe(pairingSecret);
  }
}

void _wipe(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);

sealed class PairingQrPinWrite {
  const PairingQrPinWrite();
  const factory PairingQrPinWrite.stored() = PairingQrPinStored;
  const factory PairingQrPinWrite.alreadyStored() = PairingQrPinAlreadyStored;
  const factory PairingQrPinWrite.conflict() = PairingQrPinWriteConflict;
}

final class PairingQrPinStored extends PairingQrPinWrite {
  const PairingQrPinStored();
}

final class PairingQrPinAlreadyStored extends PairingQrPinWrite {
  const PairingQrPinAlreadyStored();
}

final class PairingQrPinWriteConflict extends PairingQrPinWrite {
  const PairingQrPinWriteConflict();
}

sealed class PairingQrEvent {
  const PairingQrEvent();
}

final class PairingQrScanRequested extends PairingQrEvent {
  const PairingQrScanRequested();
}

/// Raw QR stays inside BLoC handling path; Dart strings cannot be wiped, so
/// never persist, log, or place it in state.
final class PairingQrScanned extends PairingQrEvent {
  const PairingQrScanned(this.value);

  final String value;
}

sealed class PairingQrState {
  const PairingQrState();
}

final class PairingQrIdle extends PairingQrState {
  const PairingQrIdle();
}

final class PairingQrScanning extends PairingQrState {
  const PairingQrScanning();
}

final class PairingQrScannerUnavailable extends PairingQrState {
  const PairingQrScannerUnavailable();
}

final class PairingQrAccepted extends PairingQrState {
  /// Validator-only handoff: no QR material is exposed, enrollment is not
  /// authorized, and no completion request may start from this state alone.
  const PairingQrAccepted(this.trustMode);

  final PairingQrTrustMode trustMode;
}

enum PairingQrRejection {
  malformed,
  expired,
  signature,
  continuity,
  trustUnavailable,
}

final class PairingQrRejected extends PairingQrState {
  const PairingQrRejected(this.reason);

  final PairingQrRejection reason;
}

/// Validates ADR-004's public QR boundary only. It performs no key agreement,
/// persistence, completion HTTP, or enrollment activation.
final class PairingQrBloc extends Bloc<PairingQrEvent, PairingQrState> {
  PairingQrBloc({
    required this.trustStore,
    this.scanner,
    this.credentialSink,
    PairingQrVerifier? verifier,
    DateTime Function()? now,
  }) : verifier = verifier ?? const _DefaultPairingQrVerifier(),
       _now = now ?? DateTime.now,
       super(const PairingQrIdle()) {
    on<PairingQrScanRequested>(_requestScan);
    on<PairingQrScanned>(_scan);
  }

  final PairingQrTrustStore trustStore;
  final PairingQrScanner? scanner;
  final PairingQrCredentialSink? credentialSink;
  final PairingQrVerifier verifier;
  final DateTime Function() _now;
  int _scanGeneration = 0;
  bool _scanRequestActive = false;

  Future<void> _requestScan(
    PairingQrScanRequested event,
    Emitter<PairingQrState> emit,
  ) async {
    if (_scanRequestActive) return;
    final PairingQrScanner? activeScanner = scanner;
    if (activeScanner == null) {
      emit(const PairingQrScannerUnavailable());
      return;
    }
    _scanRequestActive = true;
    try {
      final int generation = ++_scanGeneration;
      emit(const PairingQrScanning());
      final String? value;
      try {
        value = await activeScanner.scan();
      } on Object {
        if (generation == _scanGeneration) {
          emit(const PairingQrScannerUnavailable());
        }
        return;
      }
      if (generation != _scanGeneration) return;
      if (value == null) {
        emit(const PairingQrIdle());
        return;
      }
      await _scan(PairingQrScanned(value), emit);
    } finally {
      _scanRequestActive = false;
    }
  }

  Future<void> _scan(
    PairingQrScanned event,
    Emitter<PairingQrState> emit,
  ) async {
    final int generation = ++_scanGeneration;
    final PairingQrVerification? qr = await verifier.parseAndVerify(
      event.value,
    );
    if (qr == null) {
      if (generation != _scanGeneration) return;
      emit(const PairingQrRejected(PairingQrRejection.malformed));
      return;
    }
    try {
      if (generation != _scanGeneration) return;
      if (!qr.expiresAt.isAfter(_now().toUtc())) {
        emit(const PairingQrRejected(PairingQrRejection.expired));
        return;
      }
      final PairingQrPinState pin;
      try {
        pin = await trustStore.lookup(qr.fingerprint);
      } on Object {
        if (generation != _scanGeneration) return;
        emit(const PairingQrRejected(PairingQrRejection.trustUnavailable));
        return;
      }
      if (generation != _scanGeneration) return;
      if (!qr.expiresAt.isAfter(_now().toUtc())) {
        emit(const PairingQrRejected(PairingQrRejection.expired));
        return;
      }
      final bool accepted = switch ((qr.trustMode, pin)) {
        (PairingQrTrustMode.pinnedContinuity, PairingQrMatchingPin()) => true,
        // This only starts the encrypted completion flow. It neither trusts
        // the enrollment key nor activates the device: the independently
        // compared SAS and a later authenticated server decision are still
        // mandatory before either can happen.
        (PairingQrTrustMode.firstUseRequiresSas, PairingQrNoPin()) => true,
        _ => false,
      };
      if (!accepted) {
        emit(const PairingQrRejected(PairingQrRejection.continuity));
        return;
      }
      final PairingQrCredentialSink? sink = credentialSink;
      if (sink != null) {
        final PairingQrCompletionCredential credential = qr
            .completionCredential();
        try {
          await sink.accept(credential);
        } on Object {
          if (generation != _scanGeneration) return;
          emit(const PairingQrRejected(PairingQrRejection.trustUnavailable));
          return;
        } finally {
          credential.dispose();
        }
      }
      if (generation != _scanGeneration) return;
      emit(PairingQrAccepted(qr.trustMode));
    } finally {
      qr.dispose();
    }
  }
}

final class PairingQrVerification {
  const PairingQrVerification._({
    required this.endpoint,
    required this.intentId,
    required this.expiresAt,
    required this.fingerprint,
    required this.serverKeyAgreementPublicKey,
    required this.pairingSecret,
    required this.trustMode,
  });

  static const String _suite = 'X25519-crypto_kx-XChaCha20-Poly1305-IETF';
  static final RegExp _endpoint = RegExp(
    r'^https://(?=[^/:]*[a-z])[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+(?::(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?/v1/pairing/complete$',
  );
  static final RegExp _timestamp = RegExp(
    r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$',
  );
  static final RegExp _bytes16 = RegExp(r'^[A-Za-z0-9_-]{22}$');
  static final RegExp _bytes32 = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _bytes64 = RegExp(r'^[A-Za-z0-9_-]{86}$');

  final String endpoint;
  final Uint8List intentId;
  final DateTime expiresAt;
  final String fingerprint;
  final Uint8List serverKeyAgreementPublicKey;
  final Uint8List pairingSecret;
  final PairingQrTrustMode trustMode;

  static Future<PairingQrVerification?> parseAndVerify(String input) async {
    if (input.length > 4096) return null;
    final Object decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<Object?, Object?> || decoded.length != 12) return null;
    final Map<String, String>? fields = _fields(decoded);
    if (fields == null) return null;
    final String version = fields['version'] ?? '';
    final String endpoint = fields['endpoint'] ?? '';
    final String intentId = fields['intent_id'] ?? '';
    final String intentNonce = fields['intent_nonce'] ?? '';
    final String expires = fields['expires_at'] ?? '';
    final String algorithms = fields['algorithms'] ?? '';
    final String fingerprint = fields['enrollment_signing_fingerprint'] ?? '';
    final String signingKey = fields['enrollment_signing_public_key'] ?? '';
    final String serverKey = fields['server_key_agreement_public_key'] ?? '';
    final String pairingSecret = fields['pairing_secret'] ?? '';
    final String signature = fields['signature'] ?? '';
    final String mode = fields['trust_mode'] ?? '';
    if (version != '2' ||
        endpoint.length > 512 ||
        !_endpoint.hasMatch(endpoint) ||
        !_bytes16.hasMatch(intentId) ||
        !_bytes32.hasMatch(intentNonce) ||
        !_timestamp.hasMatch(expires) ||
        algorithms != _suite ||
        !_bytes32.hasMatch(fingerprint) ||
        !_bytes32.hasMatch(signingKey) ||
        !_bytes32.hasMatch(serverKey) ||
        !_bytes32.hasMatch(pairingSecret) ||
        !_bytes64.hasMatch(signature)) {
      return null;
    }
    final PairingQrTrustMode? trustMode = switch (mode) {
      'first_use_requires_sas' => PairingQrTrustMode.firstUseRequiresSas,
      'pinned_continuity' => PairingQrTrustMode.pinnedContinuity,
      _ => null,
    };
    if (trustMode == null) return null;
    final DateTime? expiry = _parseTimestamp(expires);
    Uint8List? intentIdBytes;
    Uint8List? intentNonceBytes;
    Uint8List? fingerprintBytes;
    Uint8List? signingKeyBytes;
    Uint8List? serverKeyBytes;
    Uint8List? pairingSecretBytes;
    Uint8List? signatureBytes;
    Uint8List? transcript;
    var transferredToQr = false;
    try {
      intentIdBytes = _decode(intentId, 16);
      intentNonceBytes = _decode(intentNonce, 32);
      fingerprintBytes = _decode(fingerprint, 32);
      signingKeyBytes = _decode(signingKey, 32);
      serverKeyBytes = _decode(serverKey, 32);
      pairingSecretBytes = _decode(pairingSecret, 32);
      signatureBytes = _decode(signature, 64);
      if (expiry == null ||
          intentIdBytes == null ||
          intentNonceBytes == null ||
          fingerprintBytes == null ||
          signingKeyBytes == null ||
          serverKeyBytes == null ||
          pairingSecretBytes == null ||
          signatureBytes == null ||
          !_sameBytes(
            sha256.convert(signingKeyBytes).bytes,
            fingerprintBytes,
          )) {
        return null;
      }
      transcript = _transcript(
        version: version,
        endpoint: endpoint,
        intentId: intentIdBytes,
        intentNonce: intentNonceBytes,
        expires: expires,
        algorithms: algorithms,
        signingKey: signingKeyBytes,
        fingerprint: fingerprintBytes,
        serverKey: serverKeyBytes,
        pairingSecret: pairingSecretBytes,
        trustMode: mode,
      );
      final bool verified;
      try {
        verified = await Ed25519().verify(
          transcript,
          signature: Signature(
            signatureBytes,
            publicKey: SimplePublicKey(
              signingKeyBytes,
              type: KeyPairType.ed25519,
            ),
          ),
        );
      } on Object {
        return null;
      }
      if (!verified) return null;
      final PairingQrVerification qr = PairingQrVerification._(
        endpoint: endpoint,
        intentId: intentIdBytes,
        expiresAt: expiry,
        fingerprint: fingerprint,
        serverKeyAgreementPublicKey: serverKeyBytes,
        pairingSecret: pairingSecretBytes,
        trustMode: trustMode,
      );
      transferredToQr = true;
      return qr;
    } finally {
      _wipeNullable(intentNonceBytes);
      _wipeNullable(fingerprintBytes);
      _wipeNullable(signingKeyBytes);
      _wipeNullable(signatureBytes);
      _wipeNullable(transcript);
      if (!transferredToQr) {
        _wipeNullable(intentIdBytes);
        _wipeNullable(serverKeyBytes);
        _wipeNullable(pairingSecretBytes);
      }
    }
  }

  PairingQrCompletionCredential completionCredential() =>
      PairingQrCompletionCredential._(
        endpoint: endpoint,
        intentId: intentId,
        serverKeyAgreementPublicKey: serverKeyAgreementPublicKey,
        pairingSecret: pairingSecret,
      );

  void dispose() {
    _wipe(intentId);
    _wipe(serverKeyAgreementPublicKey);
    _wipe(pairingSecret);
  }

  static Map<String, String>? _fields(Map<Object?, Object?> value) {
    const Set<String> keys = <String>{
      'version',
      'endpoint',
      'intent_id',
      'intent_nonce',
      'expires_at',
      'algorithms',
      'enrollment_signing_fingerprint',
      'enrollment_signing_public_key',
      'server_key_agreement_public_key',
      'pairing_secret',
      'signature',
      'trust_mode',
    };
    if (!value.keys.every(
      (Object? key) => key is String && keys.contains(key),
    )) {
      return null;
    }
    final Map<String, String> result = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (entry.key is! String || entry.value is! String) return null;
      result[entry.key! as String] = entry.value! as String;
    }
    return result.length == keys.length ? result : null;
  }

  static DateTime? _parseTimestamp(String value) {
    try {
      final DateTime parsed = DateTime.parse(value).toUtc();
      return parsed.toIso8601String().replaceFirst('.000Z', 'Z') == value
          ? parsed
          : null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List? _decode(String value, int length) {
    try {
      final Uint8List bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length == length &&
          base64UrlEncode(bytes).replaceAll('=', '') == value) {
        return bytes;
      }
      _wipe(bytes);
      return null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List _transcript({
    required String version,
    required String endpoint,
    required Uint8List intentId,
    required Uint8List intentNonce,
    required String expires,
    required String algorithms,
    required Uint8List signingKey,
    required Uint8List fingerprint,
    required Uint8List serverKey,
    required Uint8List pairingSecret,
    required String trustMode,
  }) {
    final BytesBuilder result = BytesBuilder(copy: false);
    for (final Uint8List field in <Uint8List>[
      Uint8List.fromList(utf8.encode('openpaycongo/pairing/qr')),
      Uint8List.fromList(utf8.encode(version)),
      Uint8List.fromList(utf8.encode(endpoint)),
      intentId,
      intentNonce,
      Uint8List.fromList(utf8.encode(expires)),
      Uint8List.fromList(utf8.encode(algorithms)),
      signingKey,
      fingerprint,
      serverKey,
      pairingSecret,
      Uint8List.fromList(utf8.encode(trustMode)),
    ]) {
      result.add(<int>[field.length >> 8, field.length & 0xff]);
      result.add(field);
    }
    return result.toBytes();
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }
}

void _wipeNullable(Uint8List? bytes) {
  if (bytes != null) _wipe(bytes);
}
