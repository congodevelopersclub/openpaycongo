import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_protocol_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_verification_screen.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_v2_crypto.dart';

void main() {
  test(
    'scanner payload is verified by the BLoC without entering its state',
    () async {
      const String rawQr = '{"not":"a trusted QR"}';
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: const _Store(),
        scanner: const _Scanner(rawQr),
      );
      final List<PairingQrState> states = <PairingQrState>[];
      final subscription = bloc.stream.listen(states.add);

      bloc.add(const PairingQrScanRequested());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(states.map((PairingQrState state) => state.runtimeType), <Type>[
        PairingQrScanning,
        PairingQrRejected,
      ]);
      expect(states.last, isA<PairingQrRejected>());
      expect(states.last.toString(), isNot(contains(rawQr)));
      await subscription.cancel();
      await bloc.close();
    },
  );

  testWidgets(
    'verification screen has an accessible scan action and safe failure copy',
    (WidgetTester tester) async {
      const String rawQr = '{"not":"a trusted QR"}';
      final PairingQrBloc bloc = PairingQrBloc(
        trustStore: const _Store(),
        scanner: const _Scanner(rawQr),
      );
      addTearDown(bloc.close);

      await tester.pumpWidget(
        MaterialApp(home: PairingQrVerificationScreen(bloc: bloc)),
      );

      expect(find.bySemanticsLabel('Scan pairing QR code'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Scan pairing QR code'));
      await tester.pumpAndSettle();

      expect(find.text('This QR code cannot be verified.'), findsOneWidget);
      expect(find.textContaining(rawQr), findsNothing);
      expect(find.text('Continue pairing'), findsNothing);
    },
  );

  testWidgets('shows only SAS while administrator confirmation is mandatory', (
    WidgetTester tester,
  ) async {
    final PairingQrBloc qr = PairingQrBloc(trustStore: const _Store());
    final PairingProtocolBloc protocol = PairingProtocolBloc(
      protocol: const _PendingProtocol(),
      vault: const _Vault(),
    );
    addTearDown(qr.close);
    addTearDown(protocol.close);

    await tester.pumpWidget(
      MaterialApp(
        home: PairingQrVerificationScreen(bloc: qr, protocol: protocol),
      ),
    );
    protocol.add(const PairingProtocolStarted(_Command()));
    await tester.pumpAndSettle();

    expect(find.textContaining('482931'), findsOneWidget);
    expect(
      find.textContaining('Administrator confirmation is mandatory'),
      findsOneWidget,
    );
    expect(
      find.textContaining('A verified QR starts encrypted pairing'),
      findsOneWidget,
    );
    expect(find.textContaining('not active'), findsOneWidget);
    expect(find.text('Scan pairing QR'), findsOneWidget);
  });

  testWidgets('confirmation action dispatches opaque activation only', (
    WidgetTester tester,
  ) async {
    final PairingQrBloc qr = PairingQrBloc(trustStore: const _Store());
    final PairingProtocolBloc protocol = PairingProtocolBloc(
      protocol: _PendingProtocol(_ActivationRequest()),
      vault: const _Vault(),
      activation: const _Activation(),
    );
    addTearDown(qr.close);
    addTearDown(protocol.close);
    await tester.pumpWidget(
      MaterialApp(home: PairingQrVerificationScreen(bloc: qr, protocol: protocol)),
    );
    protocol.add(const PairingProtocolStarted(_Command()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check activation after administrator confirms'));
    await tester.pumpAndSettle();

    expect(find.text('Pairing activated.'), findsOneWidget);
    expect(find.textContaining('bearer'), findsNothing);
  });
}

final class _Scanner implements PairingQrScanner {
  const _Scanner(this.value);

  final String value;

  @override
  Future<String?> scan() async => value;
}

final class _Store implements PairingQrTrustStore {
  const _Store();

  @override
  Future<PairingQrPinState> lookup(String fingerprint) async =>
      const PairingQrPinState.matching();

  @override
  Future<PairingQrPinWrite> persistVerifiedFingerprint(
    String fingerprint,
  ) async => const PairingQrPinWrite.alreadyStored();
}

final class _Command implements PairingProtocolCommand {
  const _Command();

  @override
  void dispose() {}
}

final class _PendingProtocol implements PairingProtocolPort {
  const _PendingProtocol([this.request]);

  final PairingActivationRequest? request;

  @override
  Future<PairingPendingMaterial> establish(
    PairingProtocolCommand command,
  ) async => PairingPendingMaterial(
    serverSas: '482931',
    keys: PairingDirectionalKeys(
      sendKey: Uint8List(32),
      receiveKey: Uint8List(32),
    ),
    activationRequest: request,
    onDispose: () {},
  );
}

final class _Vault implements PairingDirectionalKeyVault {
  const _Vault();

  @override
  Future<void> save(PairingDirectionalKeys keys) async {}
}

final class _ActivationRequest implements PairingActivationRequest {
  @override
  void dispose() {}
}

final class _Activation implements PairingActivationPort {
  const _Activation();

  @override
  Future<PairingActivationOutcome> activate(PairingActivationRequest request) async =>
      PairingActivationOutcome.activated;
}
