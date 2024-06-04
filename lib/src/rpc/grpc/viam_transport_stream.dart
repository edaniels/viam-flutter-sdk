import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:grpc/grpc.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:viam_sdk/src/exceptions.dart';

import '../../gen/proto/rpc/webrtc/v1/grpc.pb.dart' as grpc;
import 'viam_client.dart';

const _grpcStatusKey = 'grpc-status';
const _grpcMessageKey = 'grpc-message';

class ViamTransportStream extends GrpcTransportStream {
  final ViamClientChannel clientChannel;
  final grpc.Request headersRequest;
  final ErrorHandler onRequestFailure;

  bool headersSent = false;
  final List<int> receivedPacketMessageData = <int>[];

  final StreamController<List<int>> _outgoingMessages =
      StreamController<List<int>>();
  final StreamController<GrpcMessage> _incomingMessages = StreamController();

  @override
  Stream<GrpcMessage> get incomingMessages => _incomingMessages.stream;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoingMessages.sink;

  ViamTransportStream(
    this.clientChannel,
    this.headersRequest,
    this.onRequestFailure,
  ) {
    _listenToOutgoingMessages();
    _listenToChannel();
  }

  @override
  Future<void> terminate() async {
    clientChannel.removeOnMessageListener(onMessage);
    await Future.wait([
      _incomingMessages.close(),
      _outgoingMessages.close(),
    ]);
  }

  Future<void> _listenToOutgoingMessages() async {
    try {
      await for (List<int> data in _outgoingMessages.stream) {
        if (clientChannel.isDisconnected) {
          onRequestFailure(
            ConnectionLostException('${clientChannel.connectionType} lost'),
            StackTrace.current,
          );
          break;
        }

        if (!headersSent) {
          print('Write headers');
          headersSent = true;
          await clientChannel.write(headersRequest);
          print('Headers written');
        }
        print('Now writing message');
        // TODO(erd): need to adjust?
        // TODO(erd): audit this code for corectness against goutils w.r.t. stream
        // ending/closure. See Http2TransportStream as well.
        const maxMessageLength = 32 * 1024;
        final chunks = data.slices(maxMessageLength).toList();
        Iterable<grpc.Request> requests;
        if (chunks.isEmpty) {
          requests = [
            grpc.Request()
              ..stream = headersRequest.stream
              ..message = (grpc.RequestMessage()
                ..hasMessage = true
                ..eos = false
                ..packetMessage = (grpc.PacketMessage()
                  ..data = data
                  ..eom = true))
          ];
        } else {
          requests = chunks.mapIndexed((index, chunk) => grpc.Request()
            ..stream = headersRequest.stream
            ..message = (grpc.RequestMessage()
              ..hasMessage = true
              ..eos = false
              ..packetMessage = (grpc.PacketMessage()
                ..data = chunk
                ..eom = index == chunks.length - 1)));
        }
        await Future.forEach(requests, (payloadRequest) async {
          await clientChannel.write(payloadRequest);
        });
      }
      print('done with stream!');
      if (!headersSent) {
        headersSent = true;
        await clientChannel.write(headersRequest);
      }

      await clientChannel.write(grpc.Request()
        ..stream = headersRequest.stream
        ..message = (grpc.RequestMessage()
          ..hasMessage = false
          ..eos = true));
    } catch (error) {
      print('do something with this error $error');
      print('calling terminate');
      terminate();
    }
  }

  void onMessage(Uint8List data) {
    final response = grpc.Response.fromBuffer(data);

    if (response.stream.id != headersRequest.stream.id) {
      return;
    }

    final headers = response.headers;
    final trailers = response.trailers;
    final message = response.message;

    final type = response.whichType();

    switch (type) {
      case grpc.Response_Type.headers:
        _addGrpcMessage(
          GrpcMetadata(
            headers.metadata.md.map(
              (key, value) => MapEntry(
                key,
                value.values.firstOrNull ?? '',
              ),
            ),
          ),
        );
        break;
      case grpc.Response_Type.message:
        receivedPacketMessageData.addAll(message.packetMessage.data);
        if (message.packetMessage.eom) {
          _addGrpcMessage(GrpcData(
            List.unmodifiable(receivedPacketMessageData),
            isCompressed: false,
          ));
          receivedPacketMessageData.clear();
        }
        break;
      case grpc.Response_Type.trailers:
        _addGrpcMessage(GrpcMetadata({
          _grpcStatusKey: trailers.status.code.toString(),
          _grpcMessageKey: trailers.status.message,
        }));
        _incomingMessages.close();
        break;
      case grpc.Response_Type.notSet:
        break;
    }
  }

  void _listenToChannel() {
    clientChannel.addOnMessageListener(onMessage, () {
      print('termianting!');
      terminate();
    });
  }

  void _addGrpcMessage(GrpcMessage msg) {
    if (!_incomingMessages.isClosed) {
      _incomingMessages.add(msg);
    }
  }
}
