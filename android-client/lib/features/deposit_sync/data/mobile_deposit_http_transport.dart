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

abstract interface class MobileDepositHttpPort {
  Future<MobileDepositHttpResponse> post(MobileDepositHttpRequest request);
}

/// Direct HTTP boundary. Redirects are disabled; this port accepts only the
/// fixed endpoint derived from PairedMobileServerAuthority.
final class DartMobileDepositHttpPort implements MobileDepositHttpPort {
  DartMobileDepositHttpPort({HttpClient? client, int maximumResponseBytes = 1024})
    : _client = client ?? HttpClient(),
      _maximumResponseBytes = maximumResponseBytes {
    if (maximumResponseBytes < 1) {
      throw ArgumentError.value(maximumResponseBytes, 'maximumResponseBytes');
    }
  }

  final HttpClient _client;
  final int _maximumResponseBytes;

  @override
  Future<MobileDepositHttpResponse> post(MobileDepositHttpRequest request) async {
    if (!_isFixedPairedDepositUri(request.uri)) {
      throw ArgumentError('Invalid paired mobile deposit endpoint.');
    }
    final HttpClientRequest outgoing = await _client.postUrl(request.uri);
    outgoing.followRedirects = false;
    outgoing.maxRedirects = 0;
    request.headers.forEach(outgoing.headers.set);
    outgoing.add(request.body);

    final HttpClientResponse incoming = await outgoing.close();
    final List<int> body = <int>[];
    await for (final List<int> chunk in incoming) {
      final int remaining = _maximumResponseBytes + 1 - body.length;
      if (remaining > 0) body.addAll(chunk.take(remaining));
      if (body.length > _maximumResponseBytes) break;
    }
    return MobileDepositHttpResponse(status: incoming.statusCode, body: body);
  }

  void close() => _client.close(force: true);

  bool _isFixedPairedDepositUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.path == '/mobile/deposits' &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty;
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
      final MobileDepositHttpResponse response = await _http
          .post(
            MobileDepositHttpRequest(
              uri: _uri,
              headers: <String, String>{
                HttpHeaders.acceptHeader: ContentType.json.mimeType,
                HttpHeaders.authorizationHeader: 'Bearer $_bearer',
                HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
              },
              body: utf8.encode(jsonEncode(_bodyFor(deposit))),
            ),
          )
          .timeout(timeout);
      return _resultFor(response);
    } on DepositTransportUnavailable {
      rethrow;
    } on Object {
      throw const DepositTransportUnavailable();
    }
  }

  Map<String, Object> _bodyFor(ProviderDeposit deposit) => <String, Object>{
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
