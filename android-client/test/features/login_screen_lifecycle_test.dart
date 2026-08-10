import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencongopay/screens/login_screen.dart';

void main() {
  testWidgets(
    'pause hides protected content and stale authentication cannot unlock',
    (WidgetTester tester) async {
      final Completer<bool> firstAuthentication = Completer<bool>();
      final Completer<bool> resumedAuthentication = Completer<bool>();
      int attempts = 0;
      final List<bool> nativeStates = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            authenticationGeneration: () async => attempts + 1,
            authenticateForTest: () {
              attempts += 1;
              return attempts == 1
                  ? firstAuthentication.future
                  : resumedAuthentication.future;
            },
            onAuthenticationChanged: (bool unlocked, int? generation) async {
              nativeStates.add(unlocked);
            },
            child: const Text('protected payments'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('protected payments'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      firstAuthentication.complete(true);
      await tester.pump();
      expect(find.text('protected payments'), findsNothing);
      expect(nativeStates, <bool>[false]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      resumedAuthentication.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('protected payments'), findsOneWidget);
      expect(nativeStates, <bool>[false, true]);
    },
  );
}
