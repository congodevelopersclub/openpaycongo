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

class OpenCongoPayApp extends StatefulWidget {
  const OpenCongoPayApp({super.key});

  @override
  State<OpenCongoPayApp> createState() => _OpenCongoPayAppState();
}

class _OpenCongoPayAppState extends State<OpenCongoPayApp> {
  int _index = 0;

  final _pages = const <Widget>[
    PaymentInboxScreen(),
    ParsersScreen(),
    RegexBuilderScreen(),
    ConfigScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
            create: (_) => ConfigBloc(ConfigService())..add(LoadConfig())),
        BlocProvider(
            create: (_) => ParserBloc(ParserStore())..add(LoadParsers())),
      ],
      child: MaterialApp(
        title: 'OpenPay Congo',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff155d4b), brightness: Brightness.light), useMaterial3: true, scaffoldBackgroundColor: const Color(0xfff7f5ef), cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero)),
        home: LoginScreen(
          child: Scaffold(
            appBar: _index == 0 ? null : AppBar(title: const Text('OpenPay Congo')),
            body: _pages[_index],
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: _index,
              onTap: (i) => setState(() => _index = i),
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.inbox_rounded), label: 'Inbox'),
                BottomNavigationBarItem(icon: Icon(Icons.sms), label: 'Parsers'),
                BottomNavigationBarItem(icon: Icon(Icons.build), label: 'Builder'),
                BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Config'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
