import 'dart:async';
import 'dart:convert';

abstract interface class OperationalHttpPort { Future<OperationalHttpResponse> get(Uri uri, {required Map<String, String> headers}); }
abstract interface class OperationalProbe { Future<OperationalProbeResult> probe(); }
final class OperationalHttpResponse { const OperationalHttpResponse({required this.status, required this.headers, required this.body}); final int status; final Map<String, String> headers; final List<int> body; }
final class ExpectedServiceIdentity { const ExpectedServiceIdentity({required this.contractVersion, required this.migrationRevision, required this.adapter, required this.implementation}); final String contractVersion, migrationRevision, adapter, implementation; }
enum OperationalProbeFailure { http, timeout, schema, identity, superseded }
final class OperationalProbeResult { const OperationalProbeResult._({this.ready = false, this.build, this.failure}); final bool ready; final String? build; final OperationalProbeFailure? failure; factory OperationalProbeResult.ready(String build) => OperationalProbeResult._(ready: true, build: build); factory OperationalProbeResult.failure(OperationalProbeFailure value) => OperationalProbeResult._(failure: value); }

final class OperationalTransport implements OperationalProbe {
  OperationalTransport(OperationalHttpPort http, Uri base, ExpectedServiceIdentity identity, {Duration timeout = const Duration(seconds: 3)}) : this._(http, base, identity, timeout);
  OperationalTransport._(this._http, this._base, this._identity, this._timeout);
  final OperationalHttpPort _http; final Uri _base; final ExpectedServiceIdentity _identity; final Duration _timeout; int _generation = 0;
  @override
  Future<OperationalProbeResult> probe() {
    final int generation = ++_generation;
    return _probe(generation).timeout(_timeout, onTimeout: () => OperationalProbeResult.failure(OperationalProbeFailure.timeout));
  }
  Future<OperationalProbeResult> _probe(int generation) async {
    try {
      final health = await _get('/healthz');
      if (health.status != 200) return OperationalProbeResult.failure(OperationalProbeFailure.http);
      final ready = await _json('/readyz'); final version = await _json('/version');
      if (generation != _generation) return OperationalProbeResult.failure(OperationalProbeFailure.superseded);
      if (ready.$2 != 200 && ready.$2 != 503 || version.$2 != 200) return OperationalProbeResult.failure(OperationalProbeFailure.http);
      if (ready.$1 == null || version.$1 == null) return OperationalProbeResult.failure(OperationalProbeFailure.schema);
      final r = ready.$1!; final v = version.$1!;
      if (!_isReadinessSchema(r) || !_isVersionSchema(v)) return OperationalProbeResult.failure(OperationalProbeFailure.schema);
      if (!_matches(r) || !_matches(v)) return OperationalProbeResult.failure(OperationalProbeFailure.identity);
      return OperationalProbeResult._(ready: ready.$2 == 200 && r['datastore']=='ok' && r['migration']=='current' && r['topology']=='supported' && r['projection']=='healthy' && r['write_admission']=='open', build: v['build'] as String);
    } on TimeoutException { return OperationalProbeResult.failure(OperationalProbeFailure.timeout); } on FormatException { return OperationalProbeResult.failure(OperationalProbeFailure.schema); } on Object { return OperationalProbeResult.failure(OperationalProbeFailure.http); }
  }
  Future<OperationalHttpResponse> _get(String path) => _http.get(_base.resolve(path), headers: const {'cache-control':'no-store', 'accept':'application/json'});
  Future<(Map<String, Object>?, int)> _json(String path) async { final response = await _get(path); if (response.status != 200 && response.status != 503) return (null, response.status); if (response.body.length > 8192 || !((response.headers['cache-control'] ?? '').contains('no-store')) || !((response.headers['content-type'] ?? '').startsWith('application/json'))) throw const FormatException(); final value = jsonDecode(utf8.decode(response.body)); if (value is! Map) throw const FormatException(); return (Map<String, Object>.from(value), response.status); }
  bool _isReadinessSchema(Map<String, Object> value) {
    const fields = {'datastore', 'migration', 'topology', 'projection', 'write_admission', 'contract_version', 'migration_revision', 'adapter', 'implementation'};
    return value.length == fields.length && fields.every(value.containsKey) &&
      _oneOf(value['datastore'], const {'ok', 'failed'}) &&
      _oneOf(value['migration'], const {'current', 'behind', 'unknown'}) &&
      _oneOf(value['topology'], const {'supported', 'unsupported'}) &&
      _oneOf(value['projection'], const {'healthy', 'stale', 'unavailable'}) &&
      _oneOf(value['write_admission'], const {'open', 'closed'}) &&
      _text(value['contract_version']) && _text(value['migration_revision']) && _text(value['adapter']) && _text(value['implementation']);
  }
  bool _isVersionSchema(Map<String, Object> value) {
    const fields = {'build', 'contract_version', 'migration_revision', 'adapter', 'implementation'};
    return value.length == fields.length && fields.every(value.containsKey) && fields.every((field) => _text(value[field]));
  }
  bool _oneOf(Object? value, Set<String> allowed) => value is String && allowed.contains(value);
  bool _text(Object? value) => value is String && value.isNotEmpty && value.length <= 128;
  bool _matches(Map<String, Object> value) => value['contract_version']==_identity.contractVersion && value['migration_revision']==_identity.migrationRevision && value['adapter']==_identity.adapter && value['implementation']==_identity.implementation;
}
