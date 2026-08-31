import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_deposit_http_transport.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';

final class _Http implements MobileDepositHttpPort {
  _Http(this.response);

  MobileDepositHttpResponse response;
  final List<MobileDepositHttpRequest> requests = <MobileDepositHttpRequest>[];
  Object? failure;

  @override
  Future<MobileDepositHttpResponse> post(MobileDepositHttpRequest request) async {
    requests.add(request);
    if (failure case final Object error) throw error;
    return response;
  }
}

const ProviderDeposit deposit = ProviderDeposit(
  customerLookupIdentifier: 'customer-private-001',
  providerReference: 'provider-private-001',
  amountMinor: 12500,
  currency: 'CDF',
  providerOccurredAt: '2026-08-31T01:00:00Z',
  senderIdentifier: 'sender-private-001',
  customerEmail: 'customer@example.test',
);

MobileDepositHttpResponse reply(int status, String outcome) =>
    MobileDepositHttpResponse(
      status: status,
      body: utf8.encode(jsonEncode(<String, String>{'outcome': outcome})),
    );

PairedMobileServerAuthority authority() =>
    PairedMobileServerAuthority.fromVerifiedPairing(
      canonicalHttpsBaseUri: Uri.parse('https://server.example.test'),
      mobileBearer: 'opaque-bearer-token',
    );

AuthenticatedMobileDepositHttpTransport _transport(_Http http) =>
    AuthenticatedMobileDepositHttpTransport(authority: authority(), http: http);

void main() {
  test('posts exact trusted authenticated ingress contract without tenant or installation fields', () async {
    final _Http http = _Http(reply(201, 'recorded'));

    final DepositSubmissionResult result = await _transport(http).submit(deposit);

    expect(result.outcome, DepositSubmissionOutcome.recorded);
    final MobileDepositHttpRequest request = http.requests.single;
    expect(request.uri.toString(), 'https://server.example.test/mobile/deposits');
    expect(request.headers, <String, String>{
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.authorizationHeader: 'Bearer opaque-bearer-token',
      HttpHeaders.contentTypeHeader: 'application/json',
    });
    expect(jsonDecode(utf8.decode(request.body)), <String, Object>{
      'customer_lookup_identifier': 'customer-private-001',
      'provider_reference': 'provider-private-001',
      'amount_minor': 12500,
      'currency': 'CDF',
      'provider_occurred_at': '2026-08-31T01:00:00Z',
      'sender_identifier': 'sender-private-001',
      'customer_email': 'customer@example.test',
    });
  });

  test('maps only exact server acknowledgements', () async {
    for (final (int status, String outcome, DepositSubmissionOutcome expected) value
        in <(int, String, DepositSubmissionOutcome)>[
          (201, 'recorded', DepositSubmissionOutcome.recorded),
          (200, 'replayed', DepositSubmissionOutcome.replayed),
          (409, 'conflict', DepositSubmissionOutcome.conflict),
        ]) {
      final DepositSubmissionResult result = await _transport(
        _Http(reply(value.$1, value.$2)),
      ).submit(deposit);
      expect(result.outcome, value.$3);
    }
  });

  test('non-canonical, non-HTTPS, or malformed pairing authority is rejected', () {
    for (final Uri uri in <Uri>[
      Uri.parse('http://server.example.test'),
      Uri.parse('https://server.example.test/prefix'),
      Uri.parse('https://server.example.test?query=value'),
      Uri.parse('https://user@server.example.test'),
    ]) {
      expect(
        () => PairedMobileServerAuthority.fromVerifiedPairing(
          canonicalHttpsBaseUri: uri,
          mobileBearer: 'opaque-bearer-token',
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => PairedMobileServerAuthority.fromVerifiedPairing(
        canonicalHttpsBaseUri: Uri.parse('https://server.example.test'),
        mobileBearer: 'bearer with whitespace',
      ),
      throwsArgumentError,
    );
  });

  test('network, auth, redirect, malformed, oversized, and unrecognised replies fail closed', () async {
    final List<MobileDepositHttpResponse> invalid = <MobileDepositHttpResponse>[
      reply(401, 'recorded'),
      reply(403, 'recorded'),
      reply(302, 'recorded'),
      reply(201, 'replayed'),
      MobileDepositHttpResponse(status: 201, body: <int>[]),
      MobileDepositHttpResponse(status: 201, body: List<int>.filled(1025, 65)),
    ];
    for (final MobileDepositHttpResponse response in invalid) {
      await expectLater(
        _transport(_Http(response)).submit(deposit),
        throwsA(isA<DepositTransportUnavailable>()),
      );
    }

    final _Http network = _Http(reply(201, 'recorded'))
      ..failure = const SocketException('unavailable');
    await expectLater(
      _transport(network).submit(deposit),
      throwsA(isA<DepositTransportUnavailable>()),
    );
  });
}
