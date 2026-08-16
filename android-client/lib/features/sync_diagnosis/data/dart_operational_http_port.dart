import 'dart:io';

import '../domain/operational_transport.dart';

final class DartOperationalHttpPort implements OperationalHttpPort {
  DartOperationalHttpPort({HttpClient? client, int maximumBodyBytes = 8192})
      : _client = client ?? HttpClient(),
        _maximumBodyBytes = maximumBodyBytes {
    if (maximumBodyBytes < 1) throw ArgumentError.value(maximumBodyBytes, 'maximumBodyBytes');
  }

  final HttpClient _client;
  final int _maximumBodyBytes;

  @override
  Future<OperationalHttpResponse> get(Uri uri, {required Map<String, String> headers}) async {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.userInfo.isNotEmpty) throw ArgumentError.value(uri, 'uri');
    if (headers.keys.any(_isCredentialHeader)) throw ArgumentError.value(headers, 'headers');
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.maxRedirects = 0;
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = <int>[];
    await for (final chunk in response) {
      final remaining = _maximumBodyBytes + 1 - body.length;
      if (remaining > 0) body.addAll(chunk.take(remaining));
      if (body.length > _maximumBodyBytes) break;
    }
    return OperationalHttpResponse(
      status: response.statusCode,
      headers: {
        if (response.headers.value(HttpHeaders.cacheControlHeader) case final String value) HttpHeaders.cacheControlHeader: value,
        if (response.headers.value(HttpHeaders.contentTypeHeader) case final String value) HttpHeaders.contentTypeHeader: value,
      },
      body: body,
    );
  }

  void close() => _client.close(force: true);

  bool _isCredentialHeader(String name) => switch (name.toLowerCase()) {
        HttpHeaders.authorizationHeader || HttpHeaders.cookieHeader || HttpHeaders.proxyAuthorizationHeader => true,
        _ => false,
      };
}
