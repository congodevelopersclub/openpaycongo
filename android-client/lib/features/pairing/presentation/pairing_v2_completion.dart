import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pairing_protocol_bloc.dart';
import 'pairing_qr_bloc.dart';
import 'pairing_v2_crypto.dart';

/// Bridges verified QR material into an opaque BLoC command. QR bytes never
/// enter a BLoC event/state and are wiped after this method returns.
final class PairingQrProtocolCredentialSink implements PairingQrCredentialSink {
  PairingQrProtocolCredentialSink(this._bloc);

  final PairingProtocolBloc _bloc;

  @override
  Future<void> accept(PairingQrCompletionCredential credential) async {
    final PairingQrCompletionMaterial material = credential.materialize();
    PairingV2CompletionCommand? command;
    try {
      command = PairingV2CompletionCommand.fromQrMaterial(material);
      _bloc.add(PairingProtocolStarted(command));
      command = null; // BLoC now owns command disposal.
    } finally {
      command?.dispose();
      material.dispose();
    }
  }
}

/// Completion command owns a copied QR secret until `crypto_kx` consumes it.
final class PairingV2CompletionCommand implements PairingProtocolCommand {
  PairingV2CompletionCommand._({
    required this.endpoint,
    required this._credential,
    required Uint8List intentId,
  }) : _intentId = Uint8List.fromList(intentId);

  factory PairingV2CompletionCommand.fromQrMaterial(
    PairingQrCompletionMaterial material,
  ) {
    return PairingV2CompletionCommand.fromVerifiedQr(
      endpoint: material.endpoint,
      intentId: material.intentId,
      serverKeyAgreementPublicKey: material.serverKeyAgreementPublicKey,
      pairingSecret: material.pairingSecret,
    );
  }

  /// Use only at verified QR boundary. This constructor copies and consumes
  /// [pairingSecret]; caller remains responsible for wiping its source bytes.
  factory PairingV2CompletionCommand.fromVerifiedQr({
    required String endpoint,
    required Uint8List intentId,
    required Uint8List serverKeyAgreementPublicKey,
    required Uint8List pairingSecret,
  }) {
    final Uri parsedEndpoint = _validatedEndpoint(endpoint);
    final PairingV2QrCredential credential = PairingV2QrCredential(
      intentId: _base64Url(intentId),
      serverPublicKey: _base64Url(serverKeyAgreementPublicKey),
      pairingSecret: pairingSecret,
    );
    return PairingV2CompletionCommand._(
      endpoint: parsedEndpoint,
      credential: credential,
      intentId: intentId,
    );
  }

  final Uri endpoint;
  PairingV2QrCredential? _credential;
  Uint8List? _intentId;

  PairingV2QrCredential takeCredential() {
    final PairingV2QrCredential? credential = _credential;
    if (credential == null) {
      throw StateError('Pairing completion command is no longer usable');
    }
    _credential = null;
    return credential;
  }

  PairingActivationRequest takeActivationRequest() {
    final Uint8List? intentId = _intentId;
    if (intentId == null) throw StateError('Pairing activation route is no longer usable');
    _intentId = null;
    try {
      return PairingV2ActivationRequest(endpoint, intentId);
    } finally {
      intentId.fillRange(0, intentId.length, 0);
    }
  }

  @override
  void dispose() {
    final PairingV2QrCredential? credential = _credential;
    _credential = null;
    credential?.dispose();
    _intentId?.fillRange(0, _intentId!.length, 0);
    _intentId = null;
  }
}

final class PairingV2ActivationRequest implements PairingActivationRequest {
  PairingV2ActivationRequest(this.completionEndpoint, Uint8List intentId)
      : _intentId = Uint8List.fromList(intentId);

  final Uri completionEndpoint;
  Uint8List? _intentId;

  Uint8List takeIntentId() {
    final Uint8List? intentId = _intentId;
    if (intentId == null) throw StateError('Activation route disposed');
    _intentId = null;
    return intentId;
  }

  @override
  void dispose() {
    final Uint8List? intentId = _intentId;
    _intentId = null;
    intentId?.fillRange(0, intentId.length, 0);
  }
}

/// Testable HTTP boundary. Request holds no QR secret or private key.
abstract interface class PairingV2CompletionTransport {
  Future<PairingV2Response> complete(Uri endpoint, PairingV2Request request);
}

/// The request outcome is unknown. Retrying the exact request is safe because
/// the server stores an encrypted replay response for that request digest.
final class PairingV2CompletionTransientFailure implements Exception {
  const PairingV2CompletionTransientFailure();
}

/// Native Android transport for pairing. It accepts only HTTPS, never follows
/// redirects, bounds server output, and avoids logging sensitive exchanges.
final class DartIoPairingV2CompletionTransport
    implements PairingV2CompletionTransport {
  DartIoPairingV2CompletionTransport({
    this.timeout = const Duration(seconds: 15),
  });

  static const int _maximumResponseBytes = 8192;
  final Duration timeout;

  @override
  Future<PairingV2Response> complete(
    Uri endpoint,
    PairingV2Request request,
  ) async {
    _validatedEndpoint(endpoint.toString());
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _complete(client, endpoint, request).timeout(timeout);
    } on TimeoutException {
      throw const PairingV2CompletionTransientFailure();
    } on HttpException {
      throw const PairingV2CompletionTransientFailure();
    } on SocketException {
      throw const PairingV2CompletionTransientFailure();
    } finally {
      client.close(force: true);
    }
  }

  Future<PairingV2Response> _complete(
    HttpClient client,
    Uri endpoint,
    PairingV2Request request,
  ) async {
    final HttpClientRequest httpRequest = await client.postUrl(endpoint);
    httpRequest
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    httpRequest.write(
      jsonEncode(<String, String>{
        'intent_id': request.intentId,
        'client_public_key': request.clientPublicKey,
        'nonce': request.nonce,
        'ciphertext': request.ciphertext,
      }),
    );
    final HttpClientResponse response = await httpRequest.close();
    if (response.statusCode != HttpStatus.created) {
      if (_isAmbiguousStatus(response.statusCode)) {
        throw const PairingV2CompletionTransientFailure();
      }
      throw const FormatException('Pairing completion was rejected');
    }
    if (response.contentLength > _maximumResponseBytes) {
      throw const PairingV2CompletionTransientFailure();
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in response) {
      body.add(chunk);
      if (body.length > _maximumResponseBytes) {
        throw const PairingV2CompletionTransientFailure();
      }
    }
    try {
      return _parseResponse(utf8.decode(body.takeBytes(), allowMalformed: false));
    } on FormatException {
      throw const PairingV2CompletionTransientFailure();
    }
  }

  bool _isAmbiguousStatus(int statusCode) =>
      statusCode == HttpStatus.requestTimeout ||
      statusCode == HttpStatus.tooManyRequests ||
      statusCode >= HttpStatus.internalServerError;
}

/// Concrete protocol port. Its crypto adapter owns directional keys and returns
/// only the public request plus authenticated SAS to the BLoC layer.
final class PairingV2CompletionProtocol implements PairingProtocolPort {
  PairingV2CompletionProtocol({
    required this.crypto,
    required this.transport,
    this.completionDeadline = const Duration(seconds: 15),
  });

  final PairingV2CryptoPort crypto;
  final PairingV2CompletionTransport transport;
  final Duration completionDeadline;

  static const int _maximumCompletionAttempts = 2;

  @override
  Future<PairingPendingMaterial> establish(PairingProtocolCommand command) async {
    if (command is! PairingV2CompletionCommand) {
      throw ArgumentError.value(command, 'command', 'Unsupported pairing command');
    }
    try {
      final PairingV2Request request = await crypto.begin(command.takeCredential());
      final PairingV2Response response = await _completeWithRetry(
        command.endpoint,
        request,
      );
      final String sas = await crypto.accept(response);
      return PairingPendingMaterial(
        serverSas: sas,
        activationRequest: command.takeActivationRequest(),
        onDispose: () {},
      );
    } catch (_) {
      rethrow;
    } finally {
      try {
        await crypto.dispose();
      } on Object {
        // A failed best-effort cancellation must not disclose or replace the
        // original pairing failure. Native process teardown also clears it.
      }
      command.dispose();
    }
  }

  Future<PairingV2Response> _completeWithRetry(
    Uri endpoint,
    PairingV2Request request,
  ) async {
    final Stopwatch deadline = Stopwatch()..start();
    for (var attempt = 0; attempt < _maximumCompletionAttempts; attempt += 1) {
      final Duration remaining = completionDeadline - deadline.elapsed;
      if (remaining <= Duration.zero) {
        throw const PairingV2CompletionTransientFailure();
      }
      try {
        return await transport.complete(endpoint, request).timeout(remaining);
      } on TimeoutException {
        if (attempt + 1 == _maximumCompletionAttempts) {
          throw const PairingV2CompletionTransientFailure();
        }
      } on PairingV2CompletionTransientFailure {
        if (attempt + 1 == _maximumCompletionAttempts) rethrow;
      }
    }

    throw StateError('Pairing completion retry loop exhausted');
  }
}

PairingV2Response _parseResponse(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic> ||
      decoded.length != 3 ||
      decoded['state'] != 'pending_confirmation' ||
      decoded['nonce'] is! String ||
      decoded['ciphertext'] is! String) {
    throw const FormatException('Invalid pairing completion response');
  }
  return PairingV2Response(
    nonce: decoded['nonce'] as String,
    ciphertext: decoded['ciphertext'] as String,
  );
}

Uri _validatedEndpoint(String value) {
  final Uri endpoint = Uri.parse(value);
  if (endpoint.scheme != 'https' ||
      !endpoint.hasAuthority ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.path != '/v1/pairing/complete' ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw const FormatException('Invalid pairing completion endpoint');
  }
  return endpoint;
}

String _base64Url(Uint8List bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');
