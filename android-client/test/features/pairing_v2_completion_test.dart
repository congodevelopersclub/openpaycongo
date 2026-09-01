import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_protocol_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_completion.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_crypto.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('protocol sends only encrypted request, then BLoC stores copied keys',
      () async {
    final KeyPair server = sodium.crypto.kx.keyPair();
    final Uint8List secret = sodium.randombytes.buf(32);
    final _ServerTransport transport = _ServerTransport(
      sodium: sodium,
      server: server,
      expectedSecret: Uint8List.fromList(secret),
    );
    final _Vault vault = _Vault();
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: PairingV2CompletionProtocol(sodium: sodium, transport: transport),
      vault: vault,
    );
    addTearDown(() async {
      await bloc.close();
      transport.dispose();
      server.dispose();
      secret.fillRange(0, secret.length, 0);
    });

    final Uint8List qrSecret = Uint8List.fromList(secret);
    final PairingV2CompletionCommand command =
        PairingV2CompletionCommand.fromVerifiedQr(
          endpoint: 'https://pairing.example.test/v1/pairing/complete',
          intentId: sodium.randombytes.buf(16),
          serverKeyAgreementPublicKey: server.publicKey,
          pairingSecret: qrSecret,
        );
    final Future<PairingProtocolState> state = bloc.stream.firstWhere(
      (PairingProtocolState state) =>
          state is PairingProtocolAwaitingConfirmation,
    );
    bloc.add(PairingProtocolStarted(command));

    final PairingProtocolAwaitingConfirmation result =
        await state as PairingProtocolAwaitingConfirmation;
    expect(result.sas, '482901');
    expect(qrSecret, everyElement(0));
    expect(transport.received, isTrue);
    expect(transport.requestJson.contains('ciphertext'), isTrue);
    expect(transport.requestJson.contains('pairing_secret'), isFalse);
    expect(vault.sendKey, isNotNull);
    expect(vault.receiveKey, isNotNull);
  });

  test('malformed or rejected transport response returns recovery, wipes command',
      () async {
    final KeyPair server = sodium.crypto.kx.keyPair();
    final Uint8List secret = Uint8List.fromList(List<int>.filled(32, 9));
    final PairingV2CompletionCommand command =
        PairingV2CompletionCommand.fromVerifiedQr(
          endpoint: 'https://pairing.example.test/v1/pairing/complete',
          intentId: Uint8List(16),
          serverKeyAgreementPublicKey: server.publicKey,
          pairingSecret: secret,
        );
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: PairingV2CompletionProtocol(
        sodium: sodium,
        transport: const _RejectedTransport(),
      ),
      vault: _Vault(),
    );
    addTearDown(() async {
      await bloc.close();
      server.dispose();
    });

    final Future<PairingProtocolState> state = bloc.stream.firstWhere(
      (PairingProtocolState state) => state is PairingProtocolRecoveryRequired,
    );
    bloc.add(PairingProtocolStarted(command));

    expect(await state, isA<PairingProtocolRecoveryRequired>());
    expect(secret, everyElement(0));
    expect(command.takeCredential, throwsA(isA<StateError>()));
  });
}

final class _ServerTransport implements PairingV2CompletionTransport {
  _ServerTransport({
    required this.sodium,
    required this.server,
    required this.expectedSecret,
  });

  final SodiumSumo sodium;
  final KeyPair server;
  final Uint8List expectedSecret;
  late SessionKeys _keys;
  var received = false;
  late String requestJson;

  @override
  Future<PairingV2Response> complete(Uri endpoint, PairingV2Request request) async {
    received = true;
    requestJson = jsonEncode(<String, String>{
      'intent_id': request.intentId,
      'client_public_key': request.clientPublicKey,
      'nonce': request.nonce,
      'ciphertext': request.ciphertext,
    });
    _keys = sodium.crypto.kx.serverSessionKeys(
      serverPublicKey: server.publicKey,
      serverSecretKey: server.secretKey,
      clientPublicKey: _decode(request.clientPublicKey),
    );
    final Uint8List opened = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
      cipherText: _decode(request.ciphertext),
      nonce: _decode(request.nonce),
      key: _keys.rx,
      additionalData: _transcript(
        'openpaycongo/pairing/complete/v2',
        <String>[request.intentId, request.clientPublicKey],
      ),
    );
    expect(opened, expectedSecret);
    opened.fillRange(0, opened.length, 0);
    final Uint8List nonce = sodium.randombytes.buf(
      sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes,
    );
    final Uint8List ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, String>{
            'state': 'pending_confirmation',
            'short_authentication_code': '482901',
          }),
        ),
      ),
      nonce: nonce,
      key: _keys.tx,
      additionalData: _transcript(
        'openpaycongo/pairing/complete-response/v2',
        <String>[request.intentId],
      ),
    );
    return PairingV2Response(
      nonce: _base64Url(nonce),
      ciphertext: _base64Url(ciphertext),
    );
  }

  void dispose() {
    _keys.dispose();
    expectedSecret.fillRange(0, expectedSecret.length, 0);
  }
}

final class _RejectedTransport implements PairingV2CompletionTransport {
  const _RejectedTransport();

  @override
  Future<PairingV2Response> complete(Uri endpoint, PairingV2Request request) =>
      Future<PairingV2Response>.error(
        const FormatException('Pairing completion was rejected'),
      );
}

final class _Vault implements PairingDirectionalKeyVault {
  Uint8List? sendKey;
  Uint8List? receiveKey;

  @override
  Future<void> save(PairingDirectionalKeys keys) async {
    sendKey = Uint8List.fromList(keys.sendKey);
    receiveKey = Uint8List.fromList(keys.receiveKey);
  }
}

Uint8List _decode(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

String _base64Url(Uint8List value) =>
    base64UrlEncode(value).replaceAll('=', '');

Uint8List _transcript(String tag, List<String> values) {
  final BytesBuilder result = BytesBuilder(copy: false);
  for (final Uint8List field in <Uint8List>[
    Uint8List.fromList(utf8.encode(tag)),
    ...values.map(_decode),
  ]) {
    result.add(<int>[field.length >> 8, field.length & 0xff]);
    result.add(field);
  }
  return result.toBytes();
}
