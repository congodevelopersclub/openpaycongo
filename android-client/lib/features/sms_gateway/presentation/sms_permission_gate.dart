import 'package:flutter/material.dart';

import '../domain/sms_gateway.dart';

final class SmsPermissionGate extends StatefulWidget {
  const SmsPermissionGate({
    required this.gateway,
    required this.protectedBuilder,
    super.key,
  });
  final SmsGatewayPort gateway;
  final WidgetBuilder protectedBuilder;
  @override
  State<SmsPermissionGate> createState() => _SmsPermissionGateState();
}

final class _SmsPermissionGateState extends State<SmsPermissionGate>
    with WidgetsBindingObserver {
  SmsAccessState? _state;
  bool _working = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh(hideProduct: true);
    }
  }

  Future<void> _refresh({bool hideProduct = false}) async {
    final int generation = ++_generation;
    if (hideProduct && mounted) {
      setState(() => _state = null);
    }
    SmsAccessState state;
    try {
      state = await widget.gateway.permissionState();
    } on Object {
      state = SmsAccessState.unavailable;
    }
    if (mounted && generation == _generation) {
      setState(() => _state = state);
    }
  }

  Future<void> _request() async {
    if (_working) {
      return;
    }
    final int generation = ++_generation;
    setState(() {
      _working = true;
      _state = null;
    });
    SmsAccessState state;
    try {
      state = await widget.gateway.requestPermission();
    } on Object {
      state = SmsAccessState.unavailable;
    }
    if (mounted && generation == _generation) {
      setState(() {
        _state = state;
        _working = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == SmsAccessState.granted) {
      return widget.protectedBuilder(context);
    }
    final bool permanent = _state == SmsAccessState.permanentlyDenied;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Semantics(
                namesRoute: true,
                label: 'SMS permission required',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.sms_outlined, size: 56),
                    const SizedBox(height: 20),
                    Text(
                      'Receive payment SMS',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'OpenPay Congo cannot operate without receiving financial transaction SMS. Android supplies sender metadata; the app keeps only exact trusted senders in an encrypted local inbox. Raw SMS is not sent to analytics, a server, or Gemma.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No payment content is available until this permission is granted.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    if (_state == null || _working)
                      const CircularProgressIndicator()
                    else if (permanent)
                      FilledButton.icon(
                        onPressed: widget.gateway.openSettings,
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('Open app settings'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _request,
                        icon: const Icon(Icons.lock_open_outlined),
                        label: const Text('Allow SMS capture'),
                      ),
                    if (_state == SmsAccessState.unavailable) ...<Widget>[
                      const SizedBox(height: 12),
                      const Text(
                        'SMS permission status is unavailable. Check Android settings, then retry.',
                        textAlign: TextAlign.center,
                      ),
                      TextButton(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
