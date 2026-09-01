import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_protocol_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_completion.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_crypto.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late SodiumSumo sodium;
  setUpAll(() async => sodium = await SodiumSumoInit.init());

  test('Sodium test adapter completes encrypted exchange and exposes SAS only', () async {
    final KeyPair server = sodium.crypto.kx.keyPair();
    final Uint8List secret = Uint8List.fromList(List<int>.filled(32, 7));
    final PairingV2QrCredential credential = PairingV2QrCredential(
      intentId: _encode(Uint8List(16)),
      serverPublicKey: _encode(server.publicKey),
      pairingSecret: Uint8List.fromList(secret),
    );
    final SodiumPairingV2Crypto crypto = SodiumPairingV2Crypto(sodium);
    final PairingV2Request request = await crypto.begin(credential);
    final SessionKeys serverKeys = sodium.crypto.kx.serverSessionKeys(
      serverPublicKey: server.publicKey,
      serverSecretKey: server.secretKey,
      clientPublicKey: _decode(request.clientPublicKey),
    );
    try {
      final Uint8List opened = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: _decode(request.ciphertext),
        nonce: _decode(request.nonce),
        key: serverKeys.rx,
        additionalData: _transcript('openpaycongo/pairing/complete/v2', <String>[request.intentId, request.clientPublicKey]),
      );
      expect(opened, secret);
      opened.fillRange(0, opened.length, 0);
      final Uint8List nonce = Uint8List.fromList(List<int>.generate(24, (int i) => i));
      final Uint8List ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: Uint8List.fromList(utf8.encode('{"state":"pending_confirmation","short_authentication_code":"482901"}')),
        nonce: nonce,
        key: serverKeys.tx,
        additionalData: _transcript('openpaycongo/pairing/complete-response/v2', <String>[request.intentId]),
      );
      expect(await crypto.accept(PairingV2Response(nonce: _encode(nonce), ciphertext: _encode(ciphertext))), '482901');
    } finally {
      await crypto.dispose();
      serverKeys.dispose();
      server.dispose();
      secret.fillRange(0, secret.length, 0);
    }
  });

  test('completion protocol retries exact public request and returns opaque material', () async {
    final _Crypto crypto = _Crypto();
    final _RetryTransport transport = _RetryTransport();
    final PairingV2CompletionProtocol protocol = PairingV2CompletionProtocol(
      crypto: crypto,
      transport: transport,
    );
    final PairingPendingMaterial result = await protocol.establish(_command());
    expect(result.serverSas, '482901');
    expect(transport.calls, 2);
    expect(transport.exactReplay, isTrue);
    expect(crypto.disposed, isTrue);
    result.dispose();
  });

  test('native-crypto failure fails closed and protocol cancels session', () async {
    final _Crypto crypto = _Crypto(failBegin: true);
    final PairingV2CompletionProtocol protocol = PairingV2CompletionProtocol(
      crypto: crypto,
      transport: const _UnusedTransport(),
    );
    await expectLater(protocol.establish(_command()), throwsStateError);
    expect(crypto.disposed, isTrue);
  });
}

PairingV2CompletionCommand _command() => PairingV2CompletionCommand.fromVerifiedQr(
  endpoint: 'https://pairing.example.test/v1/pairing/complete',
  intentId: Uint8List(16),
  serverKeyAgreementPublicKey: Uint8List(32),
  pairingSecret: Uint8List.fromList(List<int>.filled(32, 1)),
);

final class _Crypto implements PairingV2CryptoPort {
  _Crypto({this.failBegin = false});
  final bool failBegin;
  var disposed = false;
  @override
  Future<PairingV2Request> begin(PairingV2QrCredential credential) async {
    if (failBegin) throw StateError('unavailable');
    return const PairingV2Request(intentId: 'intent', clientPublicKey: 'public', nonce: 'nonce', ciphertext: 'ciphertext');
  }
  @override
  Future<String> accept(PairingV2Response response) async => '482901';
  @override
  Future<void> dispose() async => disposed = true;
}

final class _RetryTransport implements PairingV2CompletionTransport {
  PairingV2Request? first;
  var calls = 0;
  var exactReplay = false;
  @override
  Future<PairingV2Response> complete(Uri endpoint, PairingV2Request request) async {
    calls += 1;
    if (first == null) {
      first = request;
      throw const PairingV2CompletionTransientFailure();
    }
    exactReplay = request.intentId == first!.intentId && request.clientPublicKey == first!.clientPublicKey && request.nonce == first!.nonce && request.ciphertext == first!.ciphertext;
    return const PairingV2Response(nonce: 'response-nonce', ciphertext: 'response-ciphertext');
  }
}

final class _UnusedTransport implements PairingV2CompletionTransport {
  const _UnusedTransport();
  @override
  Future<PairingV2Response> complete(Uri endpoint, PairingV2Request request) => throw UnimplementedError();
}

String _encode(Uint8List value) => base64UrlEncode(value).replaceAll('=', '');
Uint8List _decode(String value) => Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
Uint8List _transcript(String tag, List<String> fields) {
  final BytesBuilder result = BytesBuilder(copy: false);
  for (final Uint8List field in <Uint8List>[Uint8List.fromList(utf8.encode(tag)), ...fields.map(_decode)]) {
    result.add(<int>[field.length >> 8, field.length & 0xff]);
    result.add(field);
  }
  return result.toBytes();
}
