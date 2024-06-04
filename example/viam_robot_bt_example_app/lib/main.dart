import 'dart:async';
import 'dart:convert';

import 'package:ble/ble.dart' as bt;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:viam_sdk/viam_sdk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  bt.BleCentral.create().then((ble) {
    final powerStateStream = ble.getPowerState();
    late StreamSubscription<bt.PowerState> streamSub;
    streamSub = powerStateStream.listen((state) {
      if (state == bt.PowerState.poweredOn) {
        streamSub.cancel();
        connectAndTalk(ble);
      }
    });
  });

  runApp(const MyApp());
}

connectAndTalk(bt.BleCentral ble) async {
  print("will scan for device now");
  late StreamSubscription<bt.DiscoveredBleDevice> deviceSub;
  deviceSub = ble.scanForPeripherals([viamSvcUUID]).listen(
    (device) {
      if (device.name == deviceName) {
        print("found device; connecting...");
        deviceSub.cancel();
      } else {
        return;
      }
      ble.connectToDevice(device.id).then((periph) async {
        print("connected");

        final char = periph.services
            .cast<bt.BleService?>()
            .firstWhere((svc) => svc!.id == viamSvcUUID, orElse: () => null)
            ?.characteristics
            .cast<bt.BleCharacteristic?>()
            .firstWhere((char) => char!.id == viamPSMCharUUID);
        if (char == null) {
          print("did not needed PSM char after discovery");
          print("will disconnect and try again");
          await periph.disconnect();
          connectAndTalk(ble);
          return;
        }

        final val = await char.read();
        final psm = int.parse(utf8.decode(val!));
        print('will connect to psm: $psm');

        final chan = await periph.connectToL2CapChannel(psm);
        try {
          // TODO(erd): go through dial instead
          final clientChan = BluetoothClientChannel(chan, () => '');
          final armClient = ArmClient("arm1", clientChan);

          while (true) {
            try {
              print("sending command");
              final isMoving = await armClient.isMoving();
              print("arm is moving? $isMoving");
            } catch (error) {
              print('error sending $error');
              break;
            }
            print("wait");
            await Future<void>.delayed(const Duration(seconds: 90));
            print("waited");
          }
        } finally {
          chan.close();

          print("will disconnect and try again");
          await periph.disconnect();
          connectAndTalk(ble);
        }
      });
    },
    onError: (Object e) => print('connectAndTalk failed: $e'),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: 'Flutter Demo - Central (Bob)',
        theme: ThemeData(
            brightness: Brightness.dark, primaryColor: Colors.blueGrey),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Flutter Demo - Central (Bob)'),
          ),
        ),
      ),
    );
  }
}
