import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/sync_diagnosis/domain/operational_transport.dart';

final class FakePort implements OperationalHttpPort {
  FakePort(this.responses, {this.handler});
  final Map<String, Future<OperationalHttpResponse>> responses;
  final Future<OperationalHttpResponse> Function(Uri uri)? handler;
  @override
  Future<OperationalHttpResponse> get(Uri uri, {required Map<String, String> headers}) => handler?.call(uri) ?? responses[uri.path]!;
}

OperationalHttpResponse jsonResponse(int status, Map<String, Object> body) => OperationalHttpResponse(
  status: status,
  headers: const {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
  body: utf8.encode(jsonEncode(body)),
);

const identity = ExpectedServiceIdentity(contractVersion: 'v1', migrationRevision: '0004', adapter: 'sqlite', implementation: 'go');
const ready = <String, Object>{'datastore':'ok','migration':'current','topology':'supported','projection':'healthy','write_admission':'open','contract_version':'v1','migration_revision':'0004','adapter':'sqlite','implementation':'go'};
const version = <String, Object>{'build':'build-1','contract_version':'v1','migration_revision':'0004','adapter':'sqlite','implementation':'go'};

void main() {
  test('decodes bounded typed health ready and version evidence', () async {
    final client = OperationalTransport(FakePort({
      '/healthz': Future.value(const OperationalHttpResponse(status: 200, headers: {'cache-control':'no-store'}, body: <int>[])),
      '/readyz': Future.value(jsonResponse(200, ready)), '/version': Future.value(jsonResponse(200, version)),
    }), Uri.parse('https://example.invalid'), identity);
    final result = await client.probe();
    expect(result.failure, isNull); expect(result.ready, isTrue); expect(result.build, 'build-1');
  });

  test('classifies HTTP schema and identity failures fail closed', () async {
    Future<OperationalProbeResult> probe(OperationalHttpResponse response) => OperationalTransport(FakePort({
      '/healthz': Future.value(const OperationalHttpResponse(status: 200, headers: {'cache-control':'no-store'}, body: <int>[])),
      '/readyz': Future.value(response), '/version': Future.value(jsonResponse(200, version)),
    }), Uri.parse('https://example.invalid'), identity).probe();
    expect((await probe(const OperationalHttpResponse(status: 500, headers: {'cache-control':'no-store'}, body: <int>[]))).failure, OperationalProbeFailure.http);
    expect((await probe(jsonResponse(200, const {'datastore':'ok'}))).failure, OperationalProbeFailure.schema);
    final wrong = Map<String, Object>.from(ready)..['adapter'] = 'other';
    expect((await probe(jsonResponse(200, wrong))).failure, OperationalProbeFailure.identity);
  });

  test('enforces its deadline', () async {
    final old = Completer<OperationalHttpResponse>();
    final client = OperationalTransport(FakePort({
      '/healthz': old.future, '/readyz': Future.value(jsonResponse(200, ready)), '/version': Future.value(jsonResponse(200, version)),
    }), Uri.parse('https://example.invalid'), identity, timeout: const Duration(milliseconds: 1));
    expect((await client.probe()).failure, OperationalProbeFailure.timeout);
    old.complete(const OperationalHttpResponse(status: 200, headers: {'cache-control':'no-store'}, body: <int>[]));
  });

  test('shares one deadline across health readiness and version', () {
    fakeAsync((async) {
      Future<OperationalHttpResponse> delayed(OperationalHttpResponse response) => Future.delayed(const Duration(milliseconds: 6), () => response);
      final client = OperationalTransport(FakePort(const {}, handler: (uri) {
        if (uri.path == '/healthz') return delayed(const OperationalHttpResponse(status: 200, headers: {'cache-control':'no-store'}, body: <int>[]));
        return delayed(uri.path == '/readyz' ? jsonResponse(200, ready) : jsonResponse(200, version));
      }), Uri.parse('https://example.invalid'), identity, timeout: const Duration(milliseconds: 10));
      OperationalProbeResult? result;
      client.probe().then((value) => result = value);
      async.elapse(const Duration(milliseconds: 6));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 4));
      async.flushMicrotasks();
      expect(result?.failure, OperationalProbeFailure.timeout);
    });
  });

  test('supersedes a stale response when a newer probe completes', () async {
    final firstHealth = Completer<OperationalHttpResponse>();
    var healthCalls = 0;
    final client = OperationalTransport(FakePort(const {}, handler: (uri) {
      if (uri.path == '/healthz') {
        return healthCalls++ == 0 ? firstHealth.future : Future.value(const OperationalHttpResponse(status: 200, headers: {'cache-control':'no-store'}, body: <int>[]));
      }
      return Future.value(uri.path == '/readyz' ? jsonResponse(200, ready) : jsonResponse(200, version));
    }), Uri.parse('https://example.invalid'), identity);
    final stale = client.probe();
    final current = client.probe();
    firstHealth.complete(const OperationalHttpResponse(status: 200, headers: {'cache-control':'no-store'}, body: <int>[]));
    expect((await current).ready, isTrue);
    expect((await stale).failure, OperationalProbeFailure.superseded);
  });
}
