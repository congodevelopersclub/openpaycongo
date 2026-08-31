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

/// Raw QR stays inside the BLoC handling path and never appears in state.
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
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(const PairingQrIdle()) {
    on<PairingQrScanRequested>(_requestScan);
    on<PairingQrScanned>(_scan);
  }

  final PairingQrTrustStore trustStore;
  final PairingQrScanner? scanner;
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
    final _PairingQr? qr = await _PairingQr.parseAndVerify(event.value);
    if (generation != _scanGeneration) return;
    if (qr == null) {
      emit(const PairingQrRejected(PairingQrRejection.malformed));
      return;
    }
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
      (PairingQrTrustMode.firstUseRequiresSas, PairingQrNoPin()) => false,
      _ => false,
    };
    emit(
      accepted
          ? PairingQrAccepted(qr.trustMode)
          : const PairingQrRejected(PairingQrRejection.continuity),
    );
  }
}

final class _PairingQr {
  const _PairingQr({
    required this.expiresAt,
    required this.fingerprint,
    required this.trustMode,
  });

  static const String _suite = 'X25519-HKDF-SHA256-AES-256-GCM+Ed25519';
  static final RegExp _endpoint = RegExp(
    r'^https://(?=[^/:]*[a-z])[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+(?::(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?/v1/pairing/complete$',
  );
  static final RegExp _timestamp = RegExp(
    r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$',
  );
  static final RegExp _bytes16 = RegExp(r'^[A-Za-z0-9_-]{22}$');
  static final RegExp _bytes32 = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final RegExp _bytes64 = RegExp(r'^[A-Za-z0-9_-]{86}$');

  final DateTime expiresAt;
  final String fingerprint;
  final PairingQrTrustMode trustMode;

  static Future<_PairingQr?> parseAndVerify(String input) async {
    if (input.length > 4096) return null;
    final Object decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<Object?, Object?> || decoded.length != 11) return null;
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
    final String signature = fields['signature'] ?? '';
    final String mode = fields['trust_mode'] ?? '';
    if (version != '1' ||
        endpoint.length > 512 ||
        !_endpoint.hasMatch(endpoint) ||
        !_bytes16.hasMatch(intentId) ||
        !_bytes32.hasMatch(intentNonce) ||
        !_timestamp.hasMatch(expires) ||
        algorithms != _suite ||
        !_bytes32.hasMatch(fingerprint) ||
        !_bytes32.hasMatch(signingKey) ||
        !_bytes32.hasMatch(serverKey) ||
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
    final Uint8List? intentIdBytes = _decode(intentId, 16);
    final Uint8List? intentNonceBytes = _decode(intentNonce, 32);
    final Uint8List? fingerprintBytes = _decode(fingerprint, 32);
    final Uint8List? signingKeyBytes = _decode(signingKey, 32);
    final Uint8List? serverKeyBytes = _decode(serverKey, 32);
    final Uint8List? signatureBytes = _decode(signature, 64);
    if (expiry == null ||
        intentIdBytes == null ||
        intentNonceBytes == null ||
        fingerprintBytes == null ||
        signingKeyBytes == null ||
        serverKeyBytes == null ||
        signatureBytes == null ||
        !_sameBytes(sha256.convert(signingKeyBytes).bytes, fingerprintBytes)) {
      return null;
    }
    final Uint8List transcript = _transcript(
      version: version,
      endpoint: endpoint,
      intentId: intentIdBytes,
      intentNonce: intentNonceBytes,
      expires: expires,
      algorithms: algorithms,
      signingKey: signingKeyBytes,
      fingerprint: fingerprintBytes,
      serverKey: serverKeyBytes,
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
    return _PairingQr(
      expiresAt: expiry,
      fingerprint: fingerprint,
      trustMode: trustMode,
    );
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
      return bytes.length == length &&
              base64UrlEncode(bytes).replaceAll('=', '') == value
          ? bytes
          : null;
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
