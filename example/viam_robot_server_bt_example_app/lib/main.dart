import 'dart:async';

import 'package:ble/ble.dart' as bt;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:viam_sdk/viam_sdk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  bt.BlePeripheral.create().then((ble) {
    final powerStateStream = ble.getPowerState();
    late StreamSubscription<bt.PowerState> streamSub;
    streamSub = powerStateStream.listen((state) {
      if (state == bt.PowerState.poweredOn) {
        streamSub.cancel();
        publishAndListen(ble);
      }
    });
  });

  runApp(const MyApp());
}

publishAndListen(bt.BlePeripheral ble) async {
  final (psm, chanFut) = await ble.publishL2capChannel();
  print('will publish psm: $psm');
  ble.addReadOnlyService(viamSvcUUID, {viamPSMCharUUID: '$psm'});
  ble.startAdvertising(deviceName);
  final chan = await chanFut;
  // kick off another publish and listen for the next "socket"
  publishAndListen(ble);
  try {
    final server =
        BluetoothServer.create(channel: chan, services: [ArmService()]);
    print("serving");
    await server.serve();
    print("done serving");
  } finally {
    chan.close();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: 'Flutter Demo - Peripheral (Alice)',
        theme: ThemeData(
            brightness: Brightness.dark, primaryColor: Colors.blueGrey),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Flutter Demo - Peripheral (Alice)'),
          ),
        ),
      ),
    );
  }
}
