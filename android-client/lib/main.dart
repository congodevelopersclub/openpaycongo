import 'package:flutter/material.dart';

import 'features/pairing/presentation/pairing_runtime.dart';
import 'widgets/opencongopayapp.dart';
import 'services/Telemetry/telemetry.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Telemetry.instance.init();
  PairingRuntime? pairingRuntime;
  var pairingRuntimeUnavailable = false;
  try {
    pairingRuntime = await PairingRuntime.create();
  } on Object {
    pairingRuntimeUnavailable = true;
  }
  runApp(
    OpenCongoPayApp(
      pairingRuntime: pairingRuntime,
      pairingRuntimeUnavailable: pairingRuntimeUnavailable,
    ),
  );
}
