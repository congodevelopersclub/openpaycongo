import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../presentation/deposit_submission_bloc.dart';

/// Pairing-owned authority. Construct only from a signature-verified and pinned
/// pairing result. It never owns credential issuance, durable storage, or UI.
final class PairedMobileServerAuthority {
  PairedMobileServerAuthority.fromVerifiedPairing({
    required Uri canonicalHttpsBaseUri,
    required String mobileBearer,
  }) : baseUri = _requireCanonicalHttpsBaseUri(canonicalHttpsBaseUri),
       bearer = _requireBearer(mobileBearer);

  final Uri baseUri;
  final String bearer;

  static Uri _requireCanonicalHttpsBaseUri(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.path.isNotEmpty && value.path != '/' ||
        value.query.isNotEmpty ||
        value.fragment.isNotEmpty) {
      throw ArgumentError('Invalid paired mobile server authority.');
    }
    return value.replace(path: '', query: null, fragment: null);
  }

  static String _requireBearer(String value) {
    if (value.isEmpty ||
        value.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      throw ArgumentError('Invalid paired mobile bearer.');
    }
    return value;
  }
}

final class MobileDepositHttpRequest {
  MobileDepositHttpRequest({
    required this.uri,
    required Map<String, String> headers,
    required List<int> body,
  }) : headers = UnmodifiableMapView<String, String>(headers),
       body = List<int>.unmodifiable(body);

  final Uri uri;
  final Map<String, String> headers;
  final List<int> body;
}

final class MobileDepositHttpResponse {
  MobileDepositHttpResponse({required this.status, required List<int> body})
    : body = List<int>.unmodifiable(body);

  final int status;
  final List<int> body;
}

/// One in-flight request/response exchange. The owner must call [abort] when
/// it stops waiting so that an authenticated exchange cannot outlive its
/// caller and accumulate across retries.
abstract interface class MobileDepositHttpExchange {
  Future<MobileDepositHttpResponse> get response;

  void abort();
}

/// A single request's network resources. Closing a session with [force] must
/// also cancel connection setup, before an HTTP request object exists.
abstract interface class MobileDepositHttpSession {
  Future<MobileDepositHttpResponse> post(MobileDepositHttpRequest request);

  void close({required bool force});
}

abstract interface class MobileDepositHttpPort {
  MobileDepositHttpExchange post(MobileDepositHttpRequest request);
}

/// Direct HTTP boundary. Redirects are disabled; this port accepts only the
/// fixed endpoint derived from PairedMobileServerAuthority. Each exchange gets
/// its own session, so an aborted timeout can force-close stalled DNS, TCP, or
/// TLS setup without affecting a later retry.
final class DartMobileDepositHttpPort implements MobileDepositHttpPort {
  DartMobileDepositHttpPort({
    MobileDepositHttpSession Function()? openSession,
    int maximumResponseBytes = 1024,
  }) : _openSession =
           openSession ??
               (() => _DartMobileDepositHttpSession(
                 client: HttpClient(),
                 maximumResponseBytes: maximumResponseBytes,
               )) {
    if (maximumResponseBytes < 1) {
      throw ArgumentError.value(maximumResponseBytes, 'maximumResponseBytes');
    }
  }

  final MobileDepositHttpSession Function() _openSession;
  final Set<MobileDepositHttpSession> _openSessions =
      <MobileDepositHttpSession>{};

  @override
  MobileDepositHttpExchange post(MobileDepositHttpRequest request) {
    if (!_isFixedPairedDepositUri(request.uri)) {
      throw ArgumentError('Invalid paired mobile deposit endpoint.');
    }
    final MobileDepositHttpSession session = _openSession();
    _openSessions.add(session);
    return _DartMobileDepositHttpExchange(
      session: session,
      request: request,
      onFinished: () => _openSessions.remove(session),
    );
  }

  void close() {
    final List<MobileDepositHttpSession> sessions = _openSessions.toList();
    _openSessions.clear();
    for (final MobileDepositHttpSession session in sessions) {
      session.close(force: true);
    }
  }

  bool _isFixedPairedDepositUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.path == '/mobile/deposits' || uri.path == '/mobile/envelopes') &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty;
}

final class _DartMobileDepositHttpSession implements MobileDepositHttpSession {
  _DartMobileDepositHttpSession({
    required this._client,
    required this._maximumResponseBytes,
  });

  final HttpClient _client;
  final int _maximumResponseBytes;
  bool _closed = false;

  @override
  Future<MobileDepositHttpResponse> post(MobileDepositHttpRequest request) async {
    final HttpClientRequest outgoing = await _client.postUrl(request.uri);
    _throwIfClosed(outgoing);
    outgoing.followRedirects = false;
    outgoing.maxRedirects = 0;
    request.headers.forEach(outgoing.headers.set);
    outgoing.add(request.body);

    final HttpClientResponse incoming = await outgoing.close();
    _throwIfClosed(outgoing);
    final List<int> body = <int>[];
    await for (final List<int> chunk in incoming) {
      _throwIfClosed(outgoing);
      final int remaining = _maximumResponseBytes + 1 - body.length;
      if (remaining > 0) body.addAll(chunk.take(remaining));
      if (body.length > _maximumResponseBytes) break;
    }
    _throwIfClosed(outgoing);
    return MobileDepositHttpResponse(status: incoming.statusCode, body: body);
  }

  @override
  void close({required bool force}) {
    if (_closed) return;
    _closed = true;
    _client.close(force: force);
  }

  void _throwIfClosed(HttpClientRequest outgoing) {
    if (_closed) {
      outgoing.abort();
      throw const _MobileDepositHttpExchangeAborted();
    }
  }
}

final class _DartMobileDepositHttpExchange implements MobileDepositHttpExchange {
  _DartMobileDepositHttpExchange({
    required this._session,
    required this._request,
    required this._onFinished,
  });

  final MobileDepositHttpSession _session;
  final MobileDepositHttpRequest _request;
  final void Function() _onFinished;
  bool _aborted = false;
  bool _closed = false;
  bool _finished = false;

  late final Future<MobileDepositHttpResponse> _response = _post();

  @override
  Future<MobileDepositHttpResponse> get response => _response;

  @override
  void abort() {
    if (_aborted) return;
    _aborted = true;
    _closeSession(force: true);
    _finish();
  }

  Future<MobileDepositHttpResponse> _post() async {
    try {
      final MobileDepositHttpResponse response = await _session.post(_request);
      if (_aborted) throw const _MobileDepositHttpExchangeAborted();
      return response;
    } finally {
      _closeSession(force: _aborted);
      _finish();
    }
  }

  void _closeSession({required bool force}) {
    if (_closed) return;
    _closed = true;
    _session.close(force: force);
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _onFinished();
  }
}

final class _MobileDepositHttpExchangeAborted implements Exception {
  const _MobileDepositHttpExchangeAborted();
}

/// Concrete `POST /mobile/deposits` adapter. It sends only a fixed paired
/// authority and server-shaped body. Any response not proving one exact server
/// acknowledgement fails closed as unavailable.
final class AuthenticatedMobileDepositHttpTransport
    implements AuthenticatedDepositTransport {
  AuthenticatedMobileDepositHttpTransport({
    required PairedMobileServerAuthority authority,
    required this._http,
    this.maximumResponseBytes = 1024,
    this.timeout = const Duration(seconds: 3),
  }) : _uri = authority.baseUri.replace(path: '/mobile/deposits'),
       _bearer = authority.bearer {
    if (maximumResponseBytes < 1 || maximumResponseBytes > 8192) {
      throw ArgumentError.value(maximumResponseBytes, 'maximumResponseBytes');
    }
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 3)) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }

  final Uri _uri;
  final String _bearer;
  final MobileDepositHttpPort _http;
  final int maximumResponseBytes;
  final Duration timeout;

  @override
  Future<DepositSubmissionResult> submit(ProviderDeposit deposit) async {
    try {
      final MobileDepositHttpExchange exchange = _http.post(
        MobileDepositHttpRequest(
          uri: _uri,
          headers: <String, String>{
            HttpHeaders.acceptHeader: ContentType.json.mimeType,
            HttpHeaders.authorizationHeader: 'Bearer $_bearer',
            HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          },
          body: utf8.encode(jsonEncode(mobileDepositPayload(deposit))),
        ),
      );
      final MobileDepositHttpResponse response = await exchange.response.timeout(
        timeout,
        onTimeout: () {
          exchange.abort();
          throw const DepositTransportUnavailable();
        },
      );
      return _resultFor(response);
    } on DepositTransportUnavailable {
      rethrow;
    } on Object {
      throw const DepositTransportUnavailable();
    }
  }

  DepositSubmissionResult _resultFor(MobileDepositHttpResponse response) {
    if (response.body.length > maximumResponseBytes) {
      throw const DepositTransportUnavailable();
    }
    final Object? decoded = jsonDecode(
      utf8.decode(response.body, allowMalformed: false),
    );
    if (decoded is! Map<Object?, Object?> || decoded.length != 1) {
      throw const DepositTransportUnavailable();
    }
    return switch ((response.status, decoded['outcome'])) {
      (201, 'recorded') => const DepositSubmissionResult.recorded(),
      (200, 'replayed') => const DepositSubmissionResult.replayed(),
      (409, 'conflict') => const DepositSubmissionResult.conflict(),
      _ => throw const DepositTransportUnavailable(),
    };
  }
}

Map<String, Object> mobileDepositPayload(ProviderDeposit deposit) => <String, Object>{
  'customer_lookup_identifier': deposit.customerLookupIdentifier,
  'provider_reference': deposit.providerReference,
  'amount_minor': deposit.amountMinor,
  'currency': deposit.currency,
  'provider_occurred_at': deposit.providerOccurredAt,
  if (deposit.senderIdentifier case final String value) 'sender_identifier': value,
  if (deposit.receiverIdentifier case final String value)
    'receiver_identifier': value,
  if (deposit.customerName case final String value) 'customer_name': value,
  if (deposit.customerAddress case final String value) 'customer_address': value,
  if (deposit.customerPhone case final String value) 'customer_phone': value,
  if (deposit.customerEmail case final String value) 'customer_email': value,
};
