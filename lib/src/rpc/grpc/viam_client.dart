import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:protobuf/protobuf.dart';

import '../../robot/sessions_client.dart';

abstract class ViamBaseChannel {
  final List<(Function(Uint8List data), Function())> onMessageListeners = [];

  void addOnMessageListener(
          Function(Uint8List data) listener, Function() onClose) =>
      onMessageListeners.add((listener, onClose));

  void removeOnMessageListener(Function(Uint8List data) listener) {
    onMessageListeners.remove(listener);
  }

  String get connectionType;

  bool get isDisconnected;

  Future<int> write(GeneratedMessage msg);
}

abstract class ViamClientChannel extends ClientChannelBase {
  final String Function() _sessionId;
  final ViamBaseChannel baseChannel;

  ViamClientChannel(this.baseChannel, this._sessionId);

  void addOnMessageListener(
          Function(Uint8List data) listener, Function() onClose) =>
      baseChannel.onMessageListeners.add((listener, onClose));

  void removeOnMessageListener(Function(Uint8List data) listener) {
    baseChannel.onMessageListeners.remove(listener);
  }

  String get connectionType => baseChannel.connectionType;

  bool get isDisconnected => baseChannel.isDisconnected;

  Future<int> write(GeneratedMessage msg) => baseChannel.write(msg);

  @override
  ClientCall<Q, R> createCall<Q, R>(
      ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options) {
    if (!SessionsClient.unallowedMethods.contains(method.path)) {
      options = options.mergedWith(CallOptions(
          metadata: {SessionsClient.sessionMetadataKey: _sessionId()}));
    }
    return super.createCall(method, requests, options);
  }
}
