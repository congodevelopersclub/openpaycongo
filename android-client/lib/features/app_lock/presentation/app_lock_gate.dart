import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'app_lock_bloc.dart';

/// Fails closed: protected content is not constructed until [AppLockUnlocked].
final class AppLockGate extends StatefulWidget {
  const AppLockGate({
    required this.bloc,
    required this.protectedBuilder,
    super.key,
  });

  final AppLockBloc bloc;
  final WidgetBuilder protectedBuilder;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

final class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.bloc.add(const AppLockStarted());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      widget.bloc.add(
        const AppLockLifecycleChanged(AppLockLifecycle.background),
      );
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider<AppLockBloc>.value(
    value: widget.bloc,
    child: BlocBuilder<AppLockBloc, AppLockBlocState>(
      builder: (BuildContext context, AppLockBlocState state) =>
          switch (state) {
            AppLockUnlocked() => widget.protectedBuilder(context),
            AppLockEnrollmentRequired() => _enrollment(state),
            AppLockRecoveryRequired() => _recovery(),
            AppLockPinVerifying() ||
            AppLockBiometricVerifying() => _locked(verifying: true),
            AppLockLocked() => _locked(
              cooldownUntil: state.cooldownUntil,
              biometricUnavailable: state.biometricUnavailable,
            ),
            AppLockStarting() => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          },
    ),
  );

  Widget _enrollment(AppLockEnrollmentRequired state) => _page(<Widget>[
    const Text('Set a six-digit app PIN', style: TextStyle(fontSize: 24)),
    const SizedBox(height: 8),
    const Text(
      'This PIN protects local payment evidence. It cannot be recovered remotely.',
    ),
    if (state.invalid) const Text('Enter the same six-digit PIN twice.'),
    const SizedBox(height: 20),
    _pinField(_pin, 'PIN'),
    const SizedBox(height: 12),
    _pinField(_confirmation, 'Confirm PIN'),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: () {
        widget.bloc.add(
          AppLockEnrollmentSubmitted(_pin.text, _confirmation.text),
        );
        _pin.clear();
        _confirmation.clear();
      },
      child: const Text('Set app PIN'),
    ),
  ]);

  Widget _locked({
    DateTime? cooldownUntil,
    bool biometricUnavailable = false,
    bool verifying = false,
  }) => _page(<Widget>[
    const Icon(Icons.lock_outline, size: 56),
    const SizedBox(height: 16),
    const Text('App locked', style: TextStyle(fontSize: 24)),
    const SizedBox(height: 8),
    const Text(
      'Payment, sales, and sync content remains unavailable until local unlock succeeds.',
    ),
    if (cooldownUntil != null)
      Text('Try again after ${cooldownUntil.toLocal()}.'),
    if (biometricUnavailable)
      const Text('Biometric unlock is unavailable. Use your app PIN.'),
    const SizedBox(height: 20),
    _pinField(_pin, 'App PIN', enabled: !verifying && cooldownUntil == null),
    const SizedBox(height: 12),
    if (verifying)
      const CircularProgressIndicator()
    else ...<Widget>[
      FilledButton(
        onPressed: cooldownUntil == null
            ? () {
                widget.bloc.add(AppLockPinSubmitted(_pin.text));
                _pin.clear();
              }
            : null,
        child: const Text('Unlock with PIN'),
      ),
      TextButton(
        onPressed: cooldownUntil == null
            ? () => widget.bloc.add(const AppLockBiometricRequested())
            : null,
        child: const Text('Use biometrics'),
      ),
    ],
  ]);

  Widget _recovery() => _page(const <Widget>[
    Icon(Icons.warning_amber_rounded, size: 56),
    SizedBox(height: 16),
    Text('Recovery required', style: TextStyle(fontSize: 24)),
    SizedBox(height: 8),
    Text(
      'Android Clear storage or reinstall permanently removes unrecoverable local evidence. There is no unlock bypass or automatic wipe.',
    ),
  ]);

  Widget _page(List<Widget> children) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Semantics(
            container: true,
            namesRoute: true,
            label: 'App locked',
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    ),
  );

  Widget _pinField(
    TextEditingController controller,
    String label, {
    bool enabled = true,
  }) => TextField(
    controller: controller,
    enabled: enabled,
    obscureText: true,
    keyboardType: TextInputType.number,
    maxLength: 6,
    autofillHints: const <String>[],
    decoration: InputDecoration(labelText: label),
  );
}
