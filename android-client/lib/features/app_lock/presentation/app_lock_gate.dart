import 'package:flutter/material.dart';

import '../domain/app_lock.dart';

/// Fails closed: protected content is built only during an active local unlock.
final class AppLockGate extends StatefulWidget {
  const AppLockGate({required this.controller, required this.protectedBuilder, required this.now, super.key});
  final AppLockController controller;
  final WidgetBuilder protectedBuilder;
  final DateTime Function() now;
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

final class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.resume(widget.now());
      if (mounted) setState(() {});
      return;
    }
    widget.controller.background(widget.now());
    if (mounted) setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final AppLockSnapshot snapshot = widget.controller.snapshot;
    if (snapshot.state == AppLockState.unlocked) return widget.protectedBuilder(context);
    final bool verifying = snapshot.state == AppLockState.verifying;
    final bool lockedOut = snapshot.state == AppLockState.lockedOut;
    final bool delayed = snapshot.state == AppLockState.backoff;
    return Scaffold(
      body: SafeArea(child: Center(child: Semantics(
        container: true,
        namesRoute: true,
        label: 'App locked',
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          const Icon(Icons.lock_outline, size: 56),
          const SizedBox(height: 16),
          Text('App locked', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Payment, sales, and sync content remains unavailable until local unlock succeeds.', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          if (verifying) const CircularProgressIndicator()
          else if (lockedOut) const Text('Local unlock is locked out. Restart and follow the approved recovery process.')
          else ...<Widget>[
            if (delayed) const Text('Local unlock is temporarily delayed after failed attempts.'),
            FilledButton(onPressed: () => widget.controller.authenticate(widget.now()), child: const Text('Unlock app')),
          ],
          if (verifying) TextButton(onPressed: widget.controller.cancel, child: const Text('Cancel')),
        ]),
      ))),
    );
  }
}
