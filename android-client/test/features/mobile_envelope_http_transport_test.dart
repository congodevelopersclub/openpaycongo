import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_deposit_http_transport.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_envelope_http_transport.dart';
import 'package:opencongopay/features/deposit_sync/data/mobile_envelope_sealer.dart';
import 'package:opencongopay/features/deposit_sync/presentation/deposit_submission_bloc.dart';

const ProviderDeposit deposit = ProviderDeposit(
  customerLookupIdentifier: 'customer-private-001',
  providerReference: 'provider-private-001',
  amountMinor: 12500,
  currency: 'CDF',
  providerOccurredAt: '2026-09-01T01:00:00Z',
  senderIdentifier: 'sender-private-001',
  customerEmail: 'customer@example.test',
);

final class _EnvelopeVault implements MobileEnvelopeSealer {
  final List<MobileRequestEnvelope> opened = <MobileRequestEnvelope>[];
  Object? openFailure;
  MobileEnvelopeResponseOutcome openOutcome = MobileEnvelopeResponseOutcome.recorded;

  @override
  Future<MobileRequestEnvelope> sealDeposit(Uint8List payload) async {
    expect(jsonDecode(utf8.decode(payload)), <String, Object>{
      'customer_lookup_identifier': 'customer-private-001',
      'provider_reference': 'provider-private-001',
      'amount_minor': 12500,
      'currency': 'CDF',
      'provider_occurred_at': '2026-09-01T01:00:00Z',
      'sender_identifier': 'sender-private-001',
      'customer_email': 'customer@example.test',
    });
    return const MobileRequestEnvelope(
      version: 1,
      serverBaseUrl: 'https://pairing.example.test',
      installationId: '123e4567-e89b-12d3-a456-426614174000',
      counter: '1',
      nonce: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ciphertext: 'request-ciphertext',
    );
  }

  @override
  Future<MobileEnvelopeResponseOutcome> openDepositResponse({
    required MobileRequestEnvelope request,
    required int status,
    required String nonce,
    required String ciphertext,
  }) async {
    opened.add(request);
    if (openFailure case final Object error) throw error;
    expect(status, 201);
    expect(nonce, 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB');
    expect(ciphertext, 'response-ciphertext');
    return openOutcome;
  }
}

final class _Http implements MobileDepositHttpPort {
  _Http({MobileDepositHttpResponse? response})
    : response =
          response ??
          MobileDepositHttpResponse(
            status: 201,
            body: utf8.encode(jsonEncode(<String, Object>{
              'version': 1,
              'nonce': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
              'ciphertext': 'response-ciphertext',
            })),
          );

  final List<MobileDepositHttpRequest> requests = <MobileDepositHttpRequest>[];
  final MobileDepositHttpResponse response;

  @override
  MobileDepositHttpExchange post(MobileDepositHttpRequest request) {
    requests.add(request);
    return _Exchange(response);
  }
}

final class _Exchange implements MobileDepositHttpExchange {
  _Exchange(this._response);

  final MobileDepositHttpResponse _response;

  @override
  Future<MobileDepositHttpResponse> get response async => _response;

  @override
  void abort() {}
}

final class _BlockingHttp implements MobileDepositHttpPort {
  final _BlockingExchange exchange = _BlockingExchange();

  @override
  MobileDepositHttpExchange post(MobileDepositHttpRequest request) => exchange;
}

final class _BlockingExchange implements MobileDepositHttpExchange {
  final Completer<MobileDepositHttpResponse> _response =
      Completer<MobileDepositHttpResponse>();
  int abortCount = 0;

  @override
  Future<MobileDepositHttpResponse> get response => _response.future;

  @override
  void abort() {
    abortCount += 1;
    if (!_response.isCompleted) {
      _response.completeError(StateError('aborted'));
    }
  }
}

void main() {
  test('sends only a native-sealed envelope and accepts only its native-authenticated result', () async {
    final _EnvelopeVault vault = _EnvelopeVault();
    final _Http http = _Http();

    final DepositSubmissionResult result = await MobileEnvelopeHttpTransport(
      vault: vault,
      http: http,
    ).submit(deposit);

    expect(result.outcome, DepositSubmissionOutcome.recorded);
    expect(vault.opened, hasLength(1));
    final MobileDepositHttpRequest request = http.requests.single;
    expect(request.uri.toString(), 'https://pairing.example.test/mobile/envelopes');
    expect(request.headers, <String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
    });
    expect(jsonDecode(utf8.decode(request.body)), <String, Object>{
      'version': 1,
      'installation_id': '123e4567-e89b-12d3-a456-426614174000',
      'counter': '1',
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'ciphertext': 'request-ciphertext',
    });
  });

  test('rejects malformed outer responses before native decryption', () async {
    final _EnvelopeVault vault = _EnvelopeVault();
    final _Http http = _Http(
      response: MobileDepositHttpResponse(
        status: 201,
        body: utf8.encode(jsonEncode(<String, Object>{
          'version': 1,
          'nonce': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          'ciphertext': 'response-ciphertext',
          'unexpected': true,
        })),
      ),
    );

    await expectLater(
      MobileEnvelopeHttpTransport(vault: vault, http: http).submit(deposit),
      throwsA(isA<DepositTransportUnavailable>()),
    );

    expect(vault.opened, isEmpty);
  });

  test('fails closed when native response authentication fails', () async {
    final _EnvelopeVault vault = _EnvelopeVault()..openFailure = StateError('unauthenticated');

    await expectLater(
      MobileEnvelopeHttpTransport(vault: vault, http: _Http()).submit(deposit),
      throwsA(isA<DepositTransportUnavailable>()),
    );

    expect(vault.opened, hasLength(1));
  });

  test('aborts a stalled ciphertext exchange at the bounded deadline', () async {
    final _BlockingHttp http = _BlockingHttp();

    await expectLater(
      MobileEnvelopeHttpTransport(
        vault: _EnvelopeVault(),
        http: http,
        timeout: const Duration(milliseconds: 1),
      ).submit(deposit),
      throwsA(isA<DepositTransportUnavailable>()),
    );

    expect(http.exchange.abortCount, 1);
  });
}
