import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_bloc.dart';
import 'package:opencongopay/features/pairing/presentation/pairing_qr_verification_screen.dart';

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
