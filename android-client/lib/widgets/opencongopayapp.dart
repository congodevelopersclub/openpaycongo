import 'package:flutter/material.dart';
import '../screens/login_screen.dart';
import '../screens/config_screen.dart';
import '../screens/parsers_screen.dart';
import '../screens/regex_builder_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/config_bloc.dart';
import '../bloc/parser_bloc.dart';
import '../services/Config/config_service.dart';
import '../services/Parsers/parser_store.dart';
import '../features/payment_inbox/presentation/payment_inbox_screen.dart';
import '../features/sms_gateway/infrastructure/platform_sms_gateway.dart';
import '../features/sms_gateway/presentation/sms_permission_gate.dart';

class OpenCongoPayApp extends StatefulWidget {
  const OpenCongoPayApp({super.key});

  @override
  State<OpenCongoPayApp> createState() => _OpenCongoPayAppState();
}

class _OpenCongoPayAppState extends State<OpenCongoPayApp> {
  int _index = 0;
  final PlatformSmsGateway _smsGateway = const PlatformSmsGateway();

  List<Widget> get _pages => <Widget>[
    PaymentInboxScreen(
      gateway: _smsGateway,
    ),
    const ParsersScreen(),
    const RegexBuilderScreen(),
    const ConfigScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      home: SmsPermissionGate(
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
          child: LoginScreen(
            authenticationGeneration: _smsGateway.accessGeneration,
            onAuthenticationChanged: (bool unlocked, int? generation) =>
                _smsGateway.setUnlocked(unlocked, generation: generation),
            child: Scaffold(
              appBar: _index == 0
                  ? null
                  : AppBar(title: const Text('OpenPay Congo')),
              body: _pages[_index],
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: _index,
                onTap: (i) => setState(() => _index = i),
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.inbox_rounded),
                    label: 'Inbox',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.sms),
                    label: 'Parsers',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.build),
                    label: 'Builder',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings),
                    label: 'Config',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
