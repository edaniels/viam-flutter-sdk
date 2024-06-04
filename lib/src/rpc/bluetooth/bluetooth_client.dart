import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:ble/ble.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:protobuf/protobuf.dart';
import 'package:viam_sdk/src/rpc/grpc/viam_client_connection.dart';

import '../../renameme.dart';
import '../grpc/viam_client.dart';

class BluetoothBaseChannel extends ViamBaseChannel {
  L2CapChannel channel;
  @override
  final List<(Function(Uint8List data), Function())> onMessageListeners = [];

  // TODO(erd): use this to close?
  final CancelableCompleter<void> completer = CancelableCompleter<void>();

  BluetoothBaseChannel(this.channel) {
    // TODO(erd): more idiomatic way to do this?
    _readMessages(completer);
    _sendKeepAliveFramesForever();
  }

  _sendKeepAliveFramesForever() async {
    try {
      while (!completer.isCompleted) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await channel.write(keepAliveFrame);
      }
    } catch (_) {}
  }

  static const _readSize = 256;

  @override
  String get connectionType {
    return 'BluetoothConnection';
  }

  @override
  bool get isDisconnected {
    // TODO(erd): implement differently?
    return completer.isCanceled || completer.isCompleted;
  }

  @override
  Future<int> write(GeneratedMessage msg) async {
    print('writing $msg');
    return await channel.write(msgToBuf(msg));
  }

  Future<void> _readMessages(CancelableCompleter<void> completer) async {
    final byteBuf = DynamicByteBuffer();
    try {
      while (!completer.isCanceled) {
        // get message length
        // TODO(erd): need try catch logic probably...
        while (byteBuf.length < 4) {
          final readBuf = await channel.read(_readSize);
          if (readBuf != null) {
            byteBuf.write(readBuf);
          } else {
            return;
          }
        }

        final msgLenBuf = byteBuf.read(4).buffer;
        final msgLen = msgLenBuf.asByteData().getUint32(0, Endian.little);
        print('message length is $msgLen');
        if (msgLen == 0) {
          continue;
        }

        while (byteBuf.length < msgLen) {
          final readBuf = await channel.read(_readSize);
          if (readBuf != null) {
            byteBuf.write(readBuf);
          } else {
            return;
          }
        }

        final msgBuf = byteBuf.read(msgLen);
        onMessageListeners.forEach((listener) => listener.$1(msgBuf));
      }
    } catch (error) {
      print('error in _readMessages $error');
      // TODO(erd): elsewhere?
      onMessageListeners.forEach((listener) => listener.$2());
      //completer.completeError(error);
    } finally {
      if (!completer.isCompleted && !completer.isCanceled) {
        completer.complete();
      }
    }
  }

  static Uint8List msgToBuf(GeneratedMessage msg) {
    final messageBuf = msg.writeToBuffer();
    // TODO(erd): can you avoid a copy?
    final messageWithLengthPrefix = Uint8List(messageBuf.length + 4);
    messageWithLengthPrefix.buffer
        .asByteData()
        .setUint32(0, messageBuf.length, Endian.little);
    messageWithLengthPrefix.setRange(
        4, messageWithLengthPrefix.length, messageBuf);
    return messageWithLengthPrefix;
  }
}

class BluetoothClientChannel extends ViamClientChannel {
  // TODO(erd): use this to close?
  final CancelableCompleter<void> completer = CancelableCompleter<void>();

  BluetoothClientChannel(channel, sessionId)
      : super(BluetoothBaseChannel(channel), sessionId);

  @override
  ClientConnection createConnection() => ViamClientConnection(this);
}
