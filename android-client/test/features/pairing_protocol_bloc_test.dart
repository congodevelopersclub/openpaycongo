import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_protocol_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_crypto.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('QR credential owns and wipes its source secret', () {
    final Uint8List sourceSecret = Uint8List.fromList(
      List<int>.filled(32, 7),
    );
    final KeyPair server = sodium.crypto.kx.keyPair();
    final PairingV2QrCredential credential = PairingV2QrCredential(
      intentId: _base64Url(Uint8List(16)),
      serverPublicKey: _base64Url(server.publicKey),
      pairingSecret: sourceSecret,
    );
    final Uint8List ownedSecret = credential.takePairingSecret();
    try {
      expect(sourceSecret, Uint8List(32));
      expect(ownedSecret, Uint8List.fromList(List<int>.filled(32, 7)));
    } finally {
      ownedSecret.fillRange(0, ownedSecret.length, 0);
      credential.dispose();
      server.dispose();
    }
  });

  test('libsodium crypto_kx matches client transmit with server receive', () {
    final KeyPair server = sodium.crypto.kx.keyPair();
    final KeyPair client = sodium.crypto.kx.keyPair();
    final SessionKeys clientKeys = sodium.crypto.kx.clientSessionKeys(
      clientPublicKey: client.publicKey,
      clientSecretKey: client.secretKey,
      serverPublicKey: server.publicKey,
    );
    final SessionKeys serverKeys = sodium.crypto.kx.serverSessionKeys(
      serverPublicKey: server.publicKey,
      serverSecretKey: server.secretKey,
      clientPublicKey: client.publicKey,
    );
    try {
      expect(clientKeys.tx.extractBytes(), serverKeys.rx.extractBytes());
      expect(clientKeys.rx.extractBytes(), serverKeys.tx.extractBytes());
    } finally {
      clientKeys.dispose();
      serverKeys.dispose();
      client.dispose();
      server.dispose();
    }
  });

  test('request encrypts QR secret; response decrypts with receive key', () {
    final KeyPair server = sodium.crypto.kx.keyPair();
    final Uint8List secret = sodium.randombytes.buf(32);
    final PairingV2QrCredential qr = PairingV2QrCredential(
      intentId: _base64Url(sodium.randombytes.buf(16)),
      serverPublicKey: _base64Url(server.publicKey),
      pairingSecret: Uint8List.fromList(secret),
    );
    final PairingV2Exchange exchange = PairingV2Exchange.begin(sodium, qr);
    final SessionKeys serverKeys = sodium.crypto.kx.serverSessionKeys(
      serverPublicKey: server.publicKey,
      serverSecretKey: server.secretKey,
      clientPublicKey: _decode(exchange.request.clientPublicKey),
    );
    try {
      expect(
        sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: _decode(exchange.request.ciphertext),
          nonce: _decode(exchange.request.nonce),
          key: serverKeys.rx,
          additionalData: _requestAad(
            qr.intentId,
            exchange.request.clientPublicKey,
          ),
        ),
        secret,
      );

      final PairingV2Response response = _response(
        sodium: sodium,
        serverKey: serverKeys.tx,
        intentId: qr.intentId,
        sas: '482901',
      );
      final PairingDirectionalKeys keys = exchange.accept(response);

      expect(keys.sendKey, serverKeys.rx.extractBytes());
      expect(keys.receiveKey, serverKeys.tx.extractBytes());
      expect(exchange.sas, '482901');
      keys.dispose();
    } finally {
      exchange.dispose();
      serverKeys.dispose();
      server.dispose();
      secret.fillRange(0, secret.length, 0);
    }
  });

  test('tampered response or mismatched response AAD fails closed', () {
    final KeyPair server = sodium.crypto.kx.keyPair();
    final Uint8List secret = sodium.randombytes.buf(32);
    final PairingV2QrCredential qr = PairingV2QrCredential(
      intentId: _base64Url(sodium.randombytes.buf(16)),
      serverPublicKey: _base64Url(server.publicKey),
      pairingSecret: Uint8List.fromList(secret),
    );
    final PairingV2Exchange exchange = PairingV2Exchange.begin(sodium, qr);
    final SessionKeys serverKeys = sodium.crypto.kx.serverSessionKeys(
      serverPublicKey: server.publicKey,
      serverSecretKey: server.secretKey,
      clientPublicKey: _decode(exchange.request.clientPublicKey),
    );
    try {
      final PairingV2Response aadMismatch = _response(
        sodium: sodium,
        serverKey: serverKeys.tx,
        intentId: _base64Url(sodium.randombytes.buf(16)),
        sas: '482901',
      );
      expect(
        () => exchange.accept(aadMismatch),
        throwsA(isA<SodiumException>()),
      );
      expect(() => exchange.accept(aadMismatch), throwsA(isA<StateError>()));

      final PairingV2Exchange tamperedExchange = PairingV2Exchange.begin(
        sodium,
        PairingV2QrCredential(
          intentId: qr.intentId,
          serverPublicKey: qr.serverPublicKey,
          pairingSecret: Uint8List.fromList(secret),
        ),
      );
      final SessionKeys tamperedServerKeys = sodium.crypto.kx.serverSessionKeys(
        serverPublicKey: server.publicKey,
        serverSecretKey: server.secretKey,
        clientPublicKey: _decode(tamperedExchange.request.clientPublicKey),
      );
      try {
        final PairingV2Response valid = _response(
          sodium: sodium,
          serverKey: tamperedServerKeys.tx,
          intentId: qr.intentId,
          sas: '482901',
        );
        final Uint8List ciphertext = _decode(valid.ciphertext);
        ciphertext[0] ^= 1;
        expect(
          () => tamperedExchange.accept(
            PairingV2Response(
              nonce: valid.nonce,
              ciphertext: _base64Url(ciphertext),
            ),
          ),
          throwsA(isA<SodiumException>()),
        );
      } finally {
        tamperedExchange.dispose();
        tamperedServerKeys.dispose();
      }
    } finally {
      exchange.dispose();
      serverKeys.dispose();
      server.dispose();
      secret.fillRange(0, secret.length, 0);
    }
  });

  test(
    'BLoC owns opaque command only; vault copies both pending keys',
    () async {
      final _Protocol protocol = _Protocol();
      final _Vault vault = _Vault();
      final PairingProtocolBloc bloc = PairingProtocolBloc(
        protocol: protocol,
        vault: vault,
      );
      addTearDown(bloc.close);

      final Future<PairingProtocolState> result = bloc.stream.first;
      bloc.add(const PairingProtocolStarted(_Command()));

      final PairingProtocolAwaitingConfirmation state =
          await result as PairingProtocolAwaitingConfirmation;
      expect(state.sas, '482901');
      expect(state.toString(), isNot(contains('qr-secret')));
      expect(protocol.disposed, isTrue);
      expect(vault.sendKey, Uint8List.fromList(List<int>.filled(32, 1)));
      expect(vault.receiveKey, Uint8List.fromList(List<int>.filled(32, 2)));
    },
  );

  test('failed vault handoff wipes transient directional keys', () async {
    final _Protocol protocol = _Protocol();
    final PairingProtocolBloc bloc = PairingProtocolBloc(
      protocol: protocol,
      vault: _Vault(fail: true),
    );
    addTearDown(bloc.close);

    final Future<PairingProtocolState> result = bloc.stream.first;
    bloc.add(const PairingProtocolStarted(_Command()));

    expect(await result, isA<PairingProtocolRecoveryRequired>());
    expect(protocol.disposed, isTrue);
  });
}

PairingV2Response _response({
  required SodiumSumo sodium,
  required SecureKey serverKey,
  required String intentId,
  required String sas,
}) {
  final Uint8List nonce = sodium.randombytes.buf(
    sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes,
  );
  final Uint8List cipherText = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
    message: Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, String>{
          'state': 'pending_confirmation',
          'short_authentication_code': sas,
        }),
      ),
    ),
    nonce: nonce,
    key: serverKey,
    additionalData: _responseAad(intentId),
  );
  return PairingV2Response(
    nonce: _base64Url(nonce),
    ciphertext: _base64Url(cipherText),
  );
}

Uint8List _requestAad(String intentId, String clientPublicKey) => _transcript(
  'openpaycongo/pairing/complete/v2',
  <String>[intentId, clientPublicKey],
);

Uint8List _responseAad(String intentId) => _transcript(
  'openpaycongo/pairing/complete-response/v2',
  <String>[intentId],
);

Uint8List _transcript(String tag, List<String> values) {
  final BytesBuilder result = BytesBuilder(copy: false);
  final List<Uint8List> fields = <Uint8List>[
    Uint8List.fromList(utf8.encode(tag)),
    ...values.map(_decode),
  ];
  for (final Uint8List field in fields) {
    result.add(<int>[field.length >> 8, field.length & 0xff]);
    result.add(field);
  }
  return result.toBytes();
}

Uint8List _decode(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

String _base64Url(Uint8List value) =>
    base64UrlEncode(value).replaceAll('=', '');

final class _Protocol implements PairingProtocolPort {
  bool disposed = false;

  @override
  Future<PairingPendingMaterial> establish(
    PairingProtocolCommand command,
  ) async => PairingPendingMaterial(
    serverSas: '482901',
    keys: PairingDirectionalKeys(
      sendKey: Uint8List.fromList(List<int>.filled(32, 1)),
      receiveKey: Uint8List.fromList(List<int>.filled(32, 2)),
    ),
    onDispose: () => disposed = true,
  );
}

final class _Command implements PairingProtocolCommand {
  const _Command();
}

final class _Vault implements PairingDirectionalKeyVault {
  _Vault({this.fail = false});

  final bool fail;
  Uint8List? sendKey;
  Uint8List? receiveKey;

  @override
  Future<void> save(PairingDirectionalKeys keys) async {
    if (fail) throw StateError('vault unavailable');
    sendKey = Uint8List.fromList(keys.sendKey);
    receiveKey = Uint8List.fromList(keys.receiveKey);
  }
}
