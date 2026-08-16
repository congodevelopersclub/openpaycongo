import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/data/dart_operational_http_port.dart';

void main() {
  test('uses GET without credentials, does not follow redirects, and bounds retained bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var redirectedTargetRequests = 0;
    String? cacheControl;
    server.listen((request) async {
      cacheControl = request.headers.value(HttpHeaders.cacheControlHeader);
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/target');
      } else if (request.uri.path == '/target') {
        redirectedTargetRequests++;
        request.response.statusCode = HttpStatus.ok;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.add(List<int>.filled(9000, 1));
      }
      await request.response.close();
    });
    final port = DartOperationalHttpPort();
    final base = Uri.parse('http://${server.address.address}:${server.port}');
    final redirect = await port.get(base.resolve('/redirect'), headers: const {'cache-control': 'no-store', 'accept': 'application/json'});
    expect(redirect.status, HttpStatus.found);
    expect(redirectedTargetRequests, 0);
    expect(cacheControl, 'no-store');
    final bounded = await port.get(base.resolve('/large'), headers: const {'cache-control': 'no-store', 'accept': 'application/json'});
    expect(bounded.status, HttpStatus.ok);
    expect(bounded.body.length, 8193);
    port.close();
  });

  test('rejects non-http URLs and credential-bearing headers before a request', () async {
    final port = DartOperationalHttpPort();
    addTearDown(port.close);
    expect(() => port.get(Uri.parse('ftp://example.invalid/healthz'), headers: const {}), throwsArgumentError);
    expect(() => port.get(Uri.parse('https://example.invalid/healthz'), headers: const {'authorization': 'Bearer secret'}), throwsArgumentError);
  });

  test('cancels an oversized response without waiting for its stream to close', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hold = Completer<void>();
    addTearDown(() async {
      hold.complete();
      await server.close(force: true);
    });
    server.listen((request) async {
      request.response.add(List<int>.filled(8193, 1));
      await request.response.flush();
      await hold.future;
    });
    final port = DartOperationalHttpPort();
    addTearDown(port.close);
    final base = Uri.parse('http://${server.address.address}:${server.port}');

    final response = await port.get(base.resolve('/never-closes'), headers: const {'cache-control': 'no-store'}).timeout(const Duration(seconds: 1));

    expect(response.body.length, 8193);
  });
}
