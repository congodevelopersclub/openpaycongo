import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// Opaque one-time QR credential. Keep it inside pairing infrastructure.
final class PairingV2QrCredential {
  PairingV2QrCredential({
    required this.intentId,
    required this.serverPublicKey,
    required Uint8List pairingSecret,
  }) : _pairingSecret = Uint8List.fromList(pairingSecret) {
    pairingSecret.fillRange(0, pairingSecret.length, 0);
    if (_pairingSecret!.length != 32) {
      dispose();
      throw ArgumentError.value(
        pairingSecret.length,
        'pairingSecret',
        'must contain 32 bytes',
      );
    }
  }

  final String intentId;
  final String serverPublicKey;
  Uint8List? _pairingSecret;

  /// Transfers the owned secret to one exchange. It cannot be reused.
  Uint8List takePairingSecret() {
    final Uint8List? secret = _pairingSecret;
    if (secret == null) throw StateError('Pairing secret is no longer usable');
    _pairingSecret = null;
    return secret;
  }

  /// Wipes the owned secret when the scan is abandoned before exchange setup.
  void dispose() {
    final Uint8List? secret = _pairingSecret;
    _pairingSecret = null;
    secret?.fillRange(0, secret.length, 0);
  }
}

/// Transport-safe completion request. It contains no pairing secret or key.
final class PairingV2Request {
  const PairingV2Request({
    required this.intentId,
    required this.clientPublicKey,
    required this.nonce,
    required this.ciphertext,
  });

  final String intentId;
  final String clientPublicKey;
  final String nonce;
  final String ciphertext;
}

/// Transport-safe encrypted server response.
final class PairingV2Response {
  const PairingV2Response({required this.nonce, required this.ciphertext});

  final String nonce;
  final String ciphertext;
}

/// Pending directional keys. Vault must copy both before its save future ends.
///
/// `sendKey` encrypts phone-to-server envelopes. `receiveKey` decrypts
/// server-to-phone envelopes. This object is transient: caller must dispose it
/// after Android Keystore vault copies its bytes.
final class PairingDirectionalKeys {
  PairingDirectionalKeys({
    required Uint8List sendKey,
    required Uint8List receiveKey,
  }) : sendKey = Uint8List.fromList(sendKey),
       receiveKey = Uint8List.fromList(receiveKey) {
    if (this.sendKey.length != 32 || this.receiveKey.length != 32) {
      dispose();
      throw ArgumentError.value(
        <int>[sendKey.length, receiveKey.length],
        'directional keys',
        'must both contain 32 bytes',
      );
    }
  }

  final Uint8List sendKey;
  final Uint8List receiveKey;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sendKey.fillRange(0, sendKey.length, 0);
    receiveKey.fillRange(0, receiveKey.length, 0);
  }
}

/// One pairing completion exchange.
///
/// Uses libsodium's audited `crypto_kx` and XChaCha20-Poly1305-IETF APIs.
/// Session keys stay native secure memory until response verification. A bad
/// response destroys them; caller must scan a fresh QR.
final class PairingV2Exchange {
  PairingV2Exchange._({
    required this._sodium,
    required this._keys,
    required this.request,
    required this._responseAad,
  });

  final SodiumSumo _sodium;
  SessionKeys? _keys;
  Uint8List _responseAad;
  final PairingV2Request request;
  String? _sas;

  String get sas {
    final String? result = _sas;
    if (result == null) throw StateError('Pairing response not accepted');
    return result;
  }

  static PairingV2Exchange begin(
    SodiumSumo sodium,
    PairingV2QrCredential credential,
  ) {
    final Uint8List pairingSecret = credential.takePairingSecret();
    Uint8List intent = Uint8List(0);
    Uint8List serverPublicKey = Uint8List(0);
    final KeyPair client = sodium.crypto.kx.keyPair();
    SessionKeys? keys;
    Uint8List? nonce;
    Uint8List? requestAad;
    Uint8List? responseAad;
    try {
      intent = _decodeExact(credential.intentId, 16);
      serverPublicKey = _decodeExact(
        credential.serverPublicKey,
        sodium.crypto.kx.publicKeyBytes,
      );
      keys = sodium.crypto.kx.clientSessionKeys(
        clientPublicKey: client.publicKey,
        clientSecretKey: client.secretKey,
        serverPublicKey: serverPublicKey,
      );
      nonce = sodium.randombytes.buf(
        sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes,
      );
      requestAad = _requestAad(intent, client.publicKey);
      responseAad = _completionResponseAad(intent);
      final Uint8List cipherText = sodium.crypto.aeadXChaCha20Poly1305IETF
          .encrypt(
            message: pairingSecret,
            nonce: nonce,
            key: keys.tx,
            additionalData: requestAad,
          );
      final PairingV2Request request = PairingV2Request(
        intentId: credential.intentId,
        clientPublicKey: _encode(client.publicKey),
        nonce: _encode(nonce),
        ciphertext: _encode(cipherText),
      );
      final PairingV2Exchange exchange = PairingV2Exchange._(
        sodium: sodium,
        keys: keys,
        request: request,
        responseAad: responseAad,
      );
      keys = null;
      responseAad = null;
      return exchange;
    } finally {
      pairingSecret.fillRange(0, pairingSecret.length, 0);
      intent.fillRange(0, intent.length, 0);
      serverPublicKey.fillRange(0, serverPublicKey.length, 0);
      nonce?.fillRange(0, nonce.length, 0);
      requestAad?.fillRange(0, requestAad.length, 0);
      responseAad?.fillRange(0, responseAad.length, 0);
      keys?.dispose();
      // crypto_kx copied client secret into directional session keys.
      client.dispose();
    }
  }

  /// Authenticates response with client receive key, then transfers copied
  /// directional keys to caller. This exchange becomes unusable afterward.
  PairingDirectionalKeys accept(PairingV2Response response) {
    final SessionKeys keys = _takeKeys();
    Uint8List? nonce;
    Uint8List? cipherText;
    Uint8List? plaintext;
    Uint8List? sendKey;
    Uint8List? receiveKey;
    try {
      nonce = _decodeExact(
        response.nonce,
        _sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes,
      );
      cipherText = _decodeAtMost(response.ciphertext, 256);
      plaintext = _sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: cipherText,
        nonce: nonce,
        key: keys.rx,
        additionalData: _responseAad,
      );
      _sas = _readSas(plaintext);
      sendKey = keys.tx.extractBytes();
      receiveKey = keys.rx.extractBytes();
      return PairingDirectionalKeys(sendKey: sendKey, receiveKey: receiveKey);
    } finally {
      nonce?.fillRange(0, nonce.length, 0);
      cipherText?.fillRange(0, cipherText.length, 0);
      plaintext?.fillRange(0, plaintext.length, 0);
      sendKey?.fillRange(0, sendKey.length, 0);
      receiveKey?.fillRange(0, receiveKey.length, 0);
      _responseAad.fillRange(0, _responseAad.length, 0);
      _responseAad = Uint8List(0);
      keys.dispose();
    }
  }

  /// Call when transport fails or user cancels before receiving a response.
  void dispose() {
    final SessionKeys? keys = _keys;
    _keys = null;
    keys?.dispose();
    _responseAad.fillRange(0, _responseAad.length, 0);
    _responseAad = Uint8List(0);
  }

  SessionKeys _takeKeys() {
    final SessionKeys? keys = _keys;
    if (keys == null) throw StateError('Pairing exchange is no longer usable');
    _keys = null;
    return keys;
  }
}

Uint8List _requestAad(Uint8List intent, Uint8List clientPublicKey) =>
    _transcript('openpaycongo/pairing/complete/v2', <Uint8List>[
      intent,
      clientPublicKey,
    ]);

Uint8List _completionResponseAad(Uint8List intent) => _transcript(
  'openpaycongo/pairing/complete-response/v2',
  <Uint8List>[intent],
);

Uint8List _transcript(String tag, List<Uint8List> fields) {
  // Copy fields: `intent` is wiped after exchange setup and must not mutate
  // the authenticated transcript retained for the encrypted response.
  final BytesBuilder result = BytesBuilder();
  final Uint8List domain = Uint8List.fromList(utf8.encode(tag));
  for (final Uint8List field in <Uint8List>[domain, ...fields]) {
    result.add(<int>[field.length >> 8, field.length & 0xff]);
    result.add(field);
  }
  domain.fillRange(0, domain.length, 0);
  return result.toBytes();
}

String _readSas(Uint8List plaintext) {
  final Object? decoded = jsonDecode(
    utf8.decode(plaintext, allowMalformed: false),
  );
  if (decoded is! Map<String, dynamic> ||
      decoded.length != 2 ||
      decoded['state'] != 'pending_confirmation' ||
      decoded['short_authentication_code'] is! String) {
    throw const FormatException('Invalid pairing response');
  }
  final String sas = decoded['short_authentication_code'] as String;
  if (!RegExp(r'^[0-9]{6}$').hasMatch(sas)) {
    throw const FormatException('Invalid pairing response');
  }
  return sas;
}

Uint8List _decodeExact(String value, int expectedLength) {
  final Uint8List decoded = _decodeAtMost(value, expectedLength);
  if (decoded.length != expectedLength) {
    decoded.fillRange(0, decoded.length, 0);
    throw const FormatException('Invalid pairing field');
  }
  return decoded;
}

Uint8List _decodeAtMost(String value, int maximumLength) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid pairing field');
  }
  final Uint8List decoded;
  try {
    decoded = Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  } on FormatException {
    throw const FormatException('Invalid pairing field');
  }
  if (decoded.length > maximumLength || _encode(decoded) != value) {
    decoded.fillRange(0, decoded.length, 0);
    throw const FormatException('Invalid pairing field');
  }
  return decoded;
}

String _encode(Uint8List value) => base64UrlEncode(value).replaceAll('=', '');
