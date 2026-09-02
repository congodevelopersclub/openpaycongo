import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/config_bloc.dart';
import '../bloc/parser_bloc.dart';
import '../features/app_lock/infrastructure/platform_app_lock_port.dart';
import '../features/app_lock/presentation/app_lock_bloc.dart';
import '../features/app_lock/presentation/app_lock_gate.dart';
import '../features/pairing/presentation/pairing_enrollment_bloc.dart';
import '../features/pairing/presentation/pairing_qr_bloc.dart';
import '../features/pairing/presentation/pairing_protocol_bloc.dart';
import '../features/pairing/presentation/pairing_runtime.dart';
import '../features/pairing/presentation/pairing_session_bloc.dart';
import '../features/payment_inbox/presentation/payment_inbox_screen.dart';
import '../features/payment_outbox/presentation/payment_lifecycle_bloc.dart';
import '../features/payment_outbox/presentation/payment_request_lifecycle_bloc.dart';
import '../features/sms_gateway/infrastructure/platform_sms_gateway.dart';
import '../features/sms_gateway/presentation/sms_permission_gate.dart';
import '../features/sync_diagnosis/presentation/sync_cursor_bloc.dart';
import '../screens/config_screen.dart';
import '../screens/parsers_screen.dart';
import '../screens/regex_builder_screen.dart';
import '../services/Config/config_service.dart';
import '../services/Parsers/parser_store.dart';

/// Main constructs [PairingRuntime] only after native crypto initializes.
/// Tests can inject narrow BLoCs without loading native crypto.
class OpenCongoPayApp extends StatefulWidget {
  const OpenCongoPayApp({
    super.key,
    this.appLock,
    this.paymentLifecycle,
    this.paymentRequestLifecycle,
    this.pairingEnrollment,
    this.pairingSession,
    this.pairingQr,
    this.pairingProtocol,
    this.pairingRuntime,
    this.pairingRuntimeUnavailable = false,
    this.syncCursor,
  });

  final AppLockBloc? appLock;
  final PaymentLifecycle? paymentLifecycle;
  final PaymentRequestLifecycleBloc? paymentRequestLifecycle;
  final PairingEnrollmentBloc? pairingEnrollment;
  final PairingSessionBloc? pairingSession;
  final PairingQrBloc? pairingQr;
  final PairingProtocolBloc? pairingProtocol;
  final PairingRuntime? pairingRuntime;
  final bool pairingRuntimeUnavailable;
  final SyncCursorBloc? syncCursor;

  @override
  State<OpenCongoPayApp> createState() => _OpenCongoPayAppState();
}

class _OpenCongoPayAppState extends State<OpenCongoPayApp> {
  late final AppLockBloc _appLock =
      widget.appLock ?? AppLockBloc(port: const PlatformAppLockPort());
  late final bool _ownsAppLock = widget.appLock == null;
  PairingQrBloc? get _pairingQr =>
      widget.pairingQr ?? widget.pairingRuntime?.qr;
  PairingProtocolBloc? get _pairingProtocol =>
      widget.pairingProtocol ?? widget.pairingRuntime?.protocol;

  @override
  void dispose() {
    if (_ownsAppLock) _appLock.close();
    widget.pairingRuntime?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenPay Congo',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff155d4b),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f5ef),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    ),
    home: AppLockGate(
      bloc: _appLock,
      protectedBuilder: (_) => Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => _UnlockedOpenCongoPayApp(
            paymentLifecycle: widget.paymentLifecycle,
            paymentRequestLifecycle: widget.paymentRequestLifecycle,
            pairingEnrollment: widget.pairingEnrollment,
            pairingSession: widget.pairingSession,
            pairingQr: _pairingQr,
            pairingProtocol: _pairingProtocol,
            pairingRuntimeUnavailable: widget.pairingRuntimeUnavailable,
            syncCursor: widget.syncCursor,
          ),
        ),
      ),
    ),
  );
}

final class _UnlockedOpenCongoPayApp extends StatefulWidget {
  const _UnlockedOpenCongoPayApp({
    this.paymentLifecycle,
    this.paymentRequestLifecycle,
    this.pairingEnrollment,
    this.pairingSession,
    this.pairingQr,
    this.pairingProtocol,
    required this.pairingRuntimeUnavailable,
    this.syncCursor,
  });

  final PaymentLifecycle? paymentLifecycle;
  final PaymentRequestLifecycleBloc? paymentRequestLifecycle;
  final PairingEnrollmentBloc? pairingEnrollment;
  final PairingSessionBloc? pairingSession;
  final PairingQrBloc? pairingQr;
  final PairingProtocolBloc? pairingProtocol;
  final bool pairingRuntimeUnavailable;
  final SyncCursorBloc? syncCursor;

  @override
  State<_UnlockedOpenCongoPayApp> createState() =>
      _UnlockedOpenCongoPayAppState();
}

final class _UnlockedOpenCongoPayAppState
    extends State<_UnlockedOpenCongoPayApp> {
  int _index = 0;
  final PlatformSmsGateway _smsGateway = const PlatformSmsGateway();
  PaymentLifecycleBloc? _paymentLifecycleBloc;

  @override
  void initState() {
    super.initState();
    unawaited(widget.pairingProtocol?.restore() ?? Future<void>.value());
    if (widget.paymentLifecycle != null) {
      _paymentLifecycleBloc = PaymentLifecycleBloc(
        lifecycle: widget.paymentLifecycle!,
      );
    }
  }

  @override
  void dispose() {
    _paymentLifecycleBloc?.close();
    super.dispose();
  }

  List<Widget> get _pages => <Widget>[
    PaymentInboxScreen(
      gateway: _smsGateway,
      paymentLifecycle: _paymentLifecycleBloc,
      paymentRequestLifecycle: widget.paymentRequestLifecycle,
      pairingEnrollment: widget.pairingEnrollment,
      pairingSession: widget.pairingSession,
      pairingQr: widget.pairingQr,
      pairingProtocol: widget.pairingProtocol,
      pairingRuntimeUnavailable: widget.pairingRuntimeUnavailable,
      syncCursor: widget.syncCursor,
    ),
    const ParsersScreen(),
    const RegexBuilderScreen(),
    const ConfigScreen(),
  ];

  @override
  Widget build(BuildContext context) => SmsPermissionGate(
    gateway: _smsGateway,
    protectedBuilder: (BuildContext context) => MultiBlocProvider(
      providers: [
        BlocProvider<ConfigBloc>(
          create: (_) => ConfigBloc(ConfigService())..add(LoadConfig()),
        ),
        BlocProvider<ParserBloc>(
          create: (_) => ParserBloc(ParserStore())..add(LoadParsers()),
        ),
      ],
      child: Scaffold(
        appBar: _index == 0 ? null : AppBar(title: const Text('OpenPay Congo')),
        body: _pages[_index],
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _index,
          onTap: (int value) => setState(() => _index = value),
          items: const <BottomNavigationBarItem>[
            BottomNavigationBarItem(
              icon: Icon(Icons.inbox_rounded),
              label: 'Inbox',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.sms), label: 'Parsers'),
            BottomNavigationBarItem(icon: Icon(Icons.build), label: 'Builder'),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: 'Config',
            ),
          ],
        ),
      ),
    ),
  );
}
