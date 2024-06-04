import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:protobuf/protobuf.dart';
import 'package:viam_sdk/src/rpc/grpc/viam_client_connection.dart';

import '../grpc/viam_client.dart';

class WebRtcBaseChannel extends ViamBaseChannel {
  final RTCPeerConnection rtcPeerConnection;
  final RTCDataChannel dataChannel;

  WebRtcBaseChannel(this.rtcPeerConnection, this.dataChannel) {
    dataChannel.onMessage = (data) {
      onMessageListeners.forEach((listener) => listener.$1(data.binary));
    };
  }

  @override
  String get connectionType {
    return 'RTCPeerConnection';
  }

  @override
  bool get isDisconnected {
    final connectionState = rtcPeerConnection.connectionState;
    return connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;
  }

  @override
  Future<int> write(GeneratedMessage msg) async {
    final msgBuf = msg.writeToBuffer();
    await dataChannel.send(RTCDataChannelMessage.fromBinary(msgBuf));
    return msgBuf.length;
  }
}

class WebRtcClientChannel extends ViamClientChannel {
  WebRtcClientChannel(rtcPeerConnection, dataChannel, sessionId)
      : super(WebRtcBaseChannel(rtcPeerConnection, dataChannel), sessionId);

  @override
  ClientConnection createConnection() => ViamClientConnection(this);
}
