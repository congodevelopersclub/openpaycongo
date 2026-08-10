import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

class LoginScreen extends StatefulWidget {
  final Widget child;
  final Future<int> Function()? authenticationGeneration;
  final Future<void> Function(bool unlocked, int? generation)?
  onAuthenticationChanged;
  final Future<bool> Function()? authenticateForTest;
  const LoginScreen({
    super.key,
    required this.child,
    this.authenticationGeneration,
    this.onAuthenticationChanged,
    this.authenticateForTest,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  final LocalAuthentication auth = LocalAuthentication();
  bool _authenticated = false;
  bool _authenticating = false;
  int _authenticationGeneration = 0;

  Future<void> _check() async {
    if (_authenticating) {
      return;
    }
    final int generation = ++_authenticationGeneration;
    _authenticating = true;
    try {
      final int? nativeGeneration = await widget.authenticationGeneration
          ?.call();
      final bool ok =
          await (widget.authenticateForTest?.call() ??
              auth.authenticate(localizedReason: 'Authentifiez-vous'));
      if (ok &&
          mounted &&
          generation == _authenticationGeneration &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        await widget.onAuthenticationChanged?.call(true, nativeGeneration);
        if (mounted && generation == _authenticationGeneration) {
          setState(() => _authenticated = true);
        }
      }
    } catch (_) {
      // ignore
    } finally {
      if (generation == _authenticationGeneration) {
        _authenticating = false;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _check();
      return;
    }
    if (state == AppLifecycleState.inactive) {
      return;
    }
    _authenticationGeneration++;
    _authenticating = false;
    if (_authenticated) {
      setState(() => _authenticated = false);
    }
    final Future<void> Function(bool unlocked, int? generation)? callback =
        widget.onAuthenticationChanged;
    if (callback != null) {
      unawaited(callback(false, null));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_authenticated) {
      return widget.child;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Authentification')),
      body: Center(
        child: ElevatedButton(
          onPressed: _check,
          child: const Text('Se connecter'),
        ),
      ),
    );
  }
}
