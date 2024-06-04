import 'dart:async';
import 'dart:convert' show ascii;
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:ble/ble.dart';
import 'package:collection/collection.dart';
import 'package:grpc/grpc.dart' as grpc;
import 'package:http2/transport.dart';
import 'package:viam_sdk/protos/common/common.dart';
import 'package:viam_sdk/protos/component/arm.dart';
import 'package:viam_sdk/src/rpc/grpc/viam_client.dart';
import 'package:viam_sdk/viam_sdk.dart';

import './gen/proto/rpc/webrtc/v1/grpc.pb.dart' as viamgrpc;

// TODO(erd): make these something else
const viamSvcUUID = '00000000-0000-8426-0001-000000000000';
const viamPSMCharUUID = '00000000-0000-8426-0001-000000000001';
const deviceName = 'ViamBT1';
var keepAliveFrame = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);

class ActiveStream {
  final StreamController<StreamMessage> _incomingMessages = StreamController();
  List<int> receivedPacketMessageData = <int>[];

  processMessage(viamgrpc.RequestMessage message) {
    receivedPacketMessageData.addAll(message.packetMessage.data);
    // TODO(erd): does webrtc side need eos check like we do here and it does not?
    if (message.packetMessage.eom || message.eos) {
      // TODO(erd): eos correct?
      if (message.hasMessage) {
        final msgLen = receivedPacketMessageData.length;

        receivedPacketMessageData.insertAll(0, [0, 0xFF, 0XFF, 0xFF, 0xFF]);
        final lenData = ByteData(4 + receivedPacketMessageData.length);
        lenData.setUint32(0, msgLen);
        receivedPacketMessageData.setRange(1, 5, lenData.buffer.asUint8List());
        _incomingMessages.add(DataStreamMessage(receivedPacketMessageData,
            endStream: message.eos));
      }
      if (message.eos) {
        _incomingMessages.close();
      }

      // TODO(erd): is this the right way to not clear but make a new copy?
      receivedPacketMessageData = <int>[];
    }
  }
}

// TODO(erd): move me
// TODO(erd): abstract for read/write so webrtc could use this
class BluetoothServerTransportConnection implements ServerTransportConnection {
  final ViamBaseChannel _chan;
  final StreamController<ServerTransportStream> _incomingStreams =
      StreamController();
  final Map<int, ActiveStream> _activeStreams = {};

  BluetoothServerTransportConnection.forChannel(ViamBaseChannel channel)
      : _chan = channel {
    _listenToChannel();
  }

  /// Incoming HTTP/2 streams.
  @override
  Stream<ServerTransportStream> get incomingStreams => _incomingStreams.stream;

  /// Pings the other end.
  @override
  Future ping() {
    throw 'unimpl';
  }

  /// Sets the active state callback.
  ///
  /// This callback is invoked with `true` when the number of active streams
  /// goes from 0 to 1 (the connection goes from idle to active), and with
  /// `false` when the number of active streams becomes 0 (the connection goes
  /// from active to idle).
  @override
  set onActiveStateChanged(ActiveStateHandler callback) {
    throw 'unimpl';
  }

  /// Future which completes when the first SETTINGS frame is received from
  /// the peer.
  @override
  Future<void> get onInitialPeerSettingsReceived {
    throw 'unimpl';
  }

  /// Stream which emits an event with the ping id every time a ping is received
  /// on this connection.
  @override
  Stream<int> get onPingReceived {
    throw 'unimpl';
  }

  /// Stream which emits an event every time a ping is received on this
  /// connection.
  @override
  Stream<void> get onFrameReceived {
    throw 'unimpl';
  }

  /// Finish this connection.
  ///
  /// No new streams will be accepted or can be created {}
  @override
  Future finish() {
    throw 'unimpl';
  }

  /// Terminates this connection forcefully.
  @override
  Future terminate([int? errorCode]) {
    throw 'unimpl';
  }

  void onMessage(Uint8List data) {
    final request = viamgrpc.Request.fromBuffer(data);

    print('got request $request');

    final headers = request.headers;
    final message = request.message;
    final resetStream = request.rstStream;

    final type = request.whichType();

    switch (type) {
      case viamgrpc.Request_Type.headers:
        //_addGrpcMessage(
        //  grpc.GrpcMetadata(
        //    headers.metadata.md.map(
        //      (key, value) => MapEntry(
        //        key,
        //        value.values.firstOrNull ?? '',
        //      ),
        //    ),
        //  ),
        //);
        // TODO(erd): when to remove?
        // TODO(erd): copy over dupe id code
        final ActiveStream activeStream = ActiveStream();
        _activeStreams[request.stream.id.toInt()] = activeStream;
        _incomingStreams.add(BluetoothServerTransportStream(
            _chan, activeStream._incomingMessages, request.stream));

        // TODO(erd): other headers in metadata and timeout
        final grpcHeaders = [
          Header.ascii(':method', 'POST'),
          Header.ascii(':scheme', 'https'),
          Header.ascii(':path', headers.method),
        ];

        activeStream._incomingMessages.add(HeadersStreamMessage(grpcHeaders));
        break;
      case viamgrpc.Request_Type.message:
        // TODO(erd): check stream id stuff and copy code
        _activeStreams[request.stream.id.toInt()]!.processMessage(message);
        break;
      case viamgrpc.Request_Type.rstStream:
        print('do a RST_STREAM $resetStream');
        //_addGrpcMessage(grpc.GrpcMetadata({
        //  _grpcStatusKey: trailers.status.code.toString(),
        //  _grpcMessageKey: trailers.status.message,
        //}));
        //_incomingMessages.close();
        break;
      case viamgrpc.Request_Type.notSet:
        break;
    }
  }

  void _listenToChannel() {
    _chan.addOnMessageListener(onMessage, () {
      print('BluetoothServerTransportConnection call close of stream');
      _incomingStreams.close();
    });
  }
}

// TODO(erd): abstract for read/write so webrtc could use this
class BluetoothServerTransportStream extends ServerTransportStream {
  final ViamBaseChannel baseChannel;
  final StreamController<StreamMessage> _incomingMessages;
  final StreamController<StreamMessage> _outgoingMessages = StreamController();
  final viamgrpc.Stream _stream;

  BluetoothServerTransportStream(
      this.baseChannel, this._incomingMessages, this._stream) {
    _listenToOutgoingMessages();
  }

  /// The id of this stream.
  ///
  ///   * odd numbered streams are client streams
  ///   * even numbered streams are opened from the server
  @override
  int get id {
    throw 'unimpl';
  }

  /// A stream of data and/or headers from the remote end.
  @override
  Stream<StreamMessage> get incomingMessages => _incomingMessages.stream;

  /// A sink for writing data and/or headers to the remote end.
  @override
  StreamSink<StreamMessage> get outgoingMessages => _outgoingMessages.sink;

  /// Sets the termination handler on this stream.
  ///
  /// The handler will be called if the stream receives an RST_STREAM frame.
  @override
  set onTerminated(void Function(int?) value) {
    print('TODO(erd): SET ON TERM');
    //throw 'unimpl';
  }

  /// Terminates this HTTP/2 stream in an un-normal way.
  ///
  /// For normal termination, one can cancel the [StreamSubscription] from
  /// `incoming.listen()` and close the `outgoing` [StreamSink].
  ///
  /// Terminating this HTTP/2 stream will free up all resources associated with
  /// it locally and will notify the remote end that this stream is no longer
  /// used.
  @override
  void terminate() {
    throw 'unimpl';
  }

  // For convenience only.
  @override
  void sendHeaders(List<Header> headers, {bool endStream = false}) {
    outgoingMessages.add(HeadersStreamMessage(headers, endStream: endStream));
    if (endStream) outgoingMessages.close();
  }

  @override
  void sendData(List<int> bytes, {bool endStream = false}) {
    outgoingMessages.add(DataStreamMessage(bytes, endStream: endStream));
    if (endStream) outgoingMessages.close();
  }

  /// Whether a method to [push] will succeed. Requirements for this getter to
  /// return `true` are:
  ///    * this stream must be in the Open or HalfClosedRemote state
  ///    * the client needs to have the "enable push" settings enabled
  ///    * the number of active streams has not reached the maximum
  @override
  bool get canPush {
    throw 'unimpl';
  }

  /// Pushes a new stream to the remote peer.
  @override
  ServerTransportStream push(List<Header> requestHeaders) {
    throw 'unimpl';
  }

  Future<void> _listenToOutgoingMessages() async {
    // TODO(erd): does this async still work serially for multiple outgoing messages?
    await for (StreamMessage streamMsg in _outgoingMessages.stream) {
      print('got outgoing $streamMsg');
      if (baseChannel.isDisconnected) {
        //onRequestFailure(
        //  ConnectionLostException('${clientChannel.connectionType} lost'),
        //  StackTrace.current,
        //);
        break;
      }

      if (streamMsg is HeadersStreamMessage) {
        final grpcMetadata = viamgrpc.Metadata()
          ..md.addEntries(streamMsg.headers.map((header) => MapEntry(
              ascii.decode(header.name),
              viamgrpc.Strings()
                ..values.addAll([ascii.decode(header.value)]))));
        if (streamMsg.endStream) {
          // TODO(erd): missing status.
          await baseChannel.write(viamgrpc.Response()
            ..stream = _stream
            ..trailers =
                (viamgrpc.ResponseTrailers()..metadata = grpcMetadata));
        } else {
          await baseChannel.write(viamgrpc.Response()
            ..stream = _stream
            ..headers = (viamgrpc.ResponseHeaders()..metadata = grpcMetadata));
        }
      } else if (streamMsg is DataStreamMessage) {
        // data
        // TODO(erd): audit and refactor
        const maxMessageLength = 32 * 1024;
        final data = streamMsg.bytes.sublist(5);
        final chunks = data.slices(maxMessageLength).toList();
        Iterable<viamgrpc.Response> responses;
        if (chunks.isEmpty) {
          responses = [
            viamgrpc.Response()
              ..stream = _stream
              ..message = (viamgrpc.ResponseMessage()
                ..packetMessage = (viamgrpc.PacketMessage()
                  ..data = data
                  ..eom = true))
          ];
        } else {
          responses = chunks.mapIndexed((index, chunk) => viamgrpc.Response()
            ..stream = _stream
            ..message = (viamgrpc.ResponseMessage()
              ..packetMessage = (viamgrpc.PacketMessage()
                ..data = chunk
                ..eom = index == chunks.length - 1)));
        }
        await Future.forEach(responses, (payloadResponse) async {
          await baseChannel.write(payloadResponse);
        });
      } else {
        throw 'unknown StreamMessage $streamMsg';
      }
    }
  }
}

typedef GrpcErrorHandler = void Function(
    grpc.GrpcError error, StackTrace? trace);

// TODO(erd): abstract for read/write so webrtc could use this
class BluetoothServer extends grpc.ConnectionServer {
  final L2CapChannel channel;
  // TODO(erd): use this to close?
  final CancelableCompleter<void> completer = CancelableCompleter<void>();

  /// Create a server for the given [services].
  BluetoothServer.create({
    // TODO(erd): have this do listening stuff too or... no?
    required this.channel,
    required List<grpc.Service> services,
    List<grpc.Interceptor> interceptors = const <grpc.Interceptor>[],
    grpc.CodecRegistry? codecRegistry,
    GrpcErrorHandler? errorHandler,
  }) : super(
          services,
          interceptors,
          codecRegistry,
          errorHandler,
          const grpc.ServerKeepAliveOptions(),
        );

  Future<void> serve() async {
    await serveConnection(
        connection: BluetoothServerTransportConnection.forChannel(
            BluetoothBaseChannel(channel)));
    await completer.operation.value;
  }

  Future<void> shutdown() async {
    throw 'unimpl';
  }

  @override
  Future<void> serveConnection({
    required ServerTransportConnection connection,
    X509Certificate? clientCertificate,
    InternetAddress? remoteAddress,
  }) async {
    // TODO(erd): okay to keep these visible for testing bits for now?
    handlers[connection] = [];
    // TODO(jakobr): Set active state handlers, close connection after idle
    // timeout.
    final onDataReceivedController = StreamController<void>();
    onDataReceivedController.stream.listen((_) => print('@@data recevied@@'));
    connection.incomingStreams.listen((stream) {
      final handler = serveStream_(
        stream: stream,
        clientCertificate: clientCertificate,
        remoteAddress: remoteAddress,
        onDataReceived: onDataReceivedController.sink,
      );
      handler.onCanceled.then((_) {
        print('handler canceled??');
        handlers[connection]?.remove(handler);
      });
      handlers[connection]!.add(handler);
    }, onError: (error, stackTrace) {
      print('ERROR HAPPENED $error $stackTrace');
      if (error is Error) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }, onDone: () async {
      // TODO(sigurdm): This is not correct behavior in the presence of
      // half-closed tcp streams.
      // Half-closed  streams seems to not be fully supported by package:http2.
      // https://github.com/dart-lang/http2/issues/42
      for (var handler in handlers[connection]!) {
        handler.cancel();
      }
      handlers.remove(connection);
      await onDataReceivedController.close();
    });
  }
}

// TODO(erd): handle throw bubbling up. probably because we're not setting status but just metdata
// in viam grpc proto.
class ArmService extends ArmServiceBase {
  @override
  Future<GetEndPositionResponse> getEndPosition(
      grpc.ServiceCall call, GetEndPositionRequest request) {
    throw 'unimpl';
  }

  @override
  Future<MoveToPositionResponse> moveToPosition(
      grpc.ServiceCall call, MoveToPositionRequest request) {
    throw 'unimpl';
  }

  @override
  Future<GetJointPositionsResponse> getJointPositions(
      grpc.ServiceCall call, GetJointPositionsRequest request) {
    throw 'unimpl';
  }

  @override
  Future<MoveToJointPositionsResponse> moveToJointPositions(
      grpc.ServiceCall call, MoveToJointPositionsRequest request) {
    throw 'unimpl';
  }

  @override
  Future<StopResponse> stop(grpc.ServiceCall call, StopRequest request) {
    throw 'unimpl';
  }

  @override
  Future<IsMovingResponse> isMoving(
      grpc.ServiceCall call, IsMovingRequest request) async {
    print('@@@@@@@ISMOVING CALLED');
    return IsMovingResponse()..isMoving = true;
  }

  @override
  Future<DoCommandResponse> doCommand(
      grpc.ServiceCall call, DoCommandRequest request) {
    throw 'unimpl';
  }

  @override
  Future<GetKinematicsResponse> getKinematics(
      grpc.ServiceCall call, GetKinematicsRequest request) {
    throw 'unimpl';
  }

  @override
  Future<GetGeometriesResponse> getGeometries(
      grpc.ServiceCall call, GetGeometriesRequest request) {
    throw 'unimpl';
  }
}

// TODO(erd): dedupe and refactor
class DynamicByteBuffer {
  final _debugRemoveMe = false;
  final List<Uint8List> _allBufs = [];
  int _allBufsSize = 0;
  int _currentBufPos = 0;

  DynamicByteBuffer();

  int get length {
    return _allBufsSize;
  }

  write(Uint8List buf) {
    _allBufs.add(buf);
    _allBufsSize += buf.length;
  }

  Uint8List read(int length) {
    if (_debugRemoveMe) {
      print(
          'want to read $length; _allBufs.length: ${_allBufs.length} _allBufsSize: $_allBufsSize _currentBufPos: $_currentBufPos');
    }
    if (_allBufsSize < length) {
      throw 'too small';
    }
    final result = Uint8List(length);
    var bytesWritten = 0;
    var bytesRemaining = length;
    while (bytesRemaining != 0) {
      final buf = _allBufs.first;

      var bytesToPull = 0;
      final bytesAvailable = buf.length - _currentBufPos;
      if (bytesRemaining >= bytesAvailable) {
        // we will consume the whole buffer
        bytesToPull = bytesAvailable;
      } else {
        // we wil maintain this buffer
        bytesToPull = bytesRemaining;
      }
      if (_debugRemoveMe) {
        print(
            'will set range [$bytesWritten, ${bytesWritten + bytesToPull}] with buf[$_currentBufPos:${_currentBufPos + bytesToPull}]');
      }
      result.setRange(bytesWritten, bytesWritten + bytesToPull,
          buf.getRange(_currentBufPos, _currentBufPos + bytesToPull));

      // update counts

      // move forward
      _currentBufPos += bytesToPull;
      bytesWritten += bytesToPull;

      // move backward
      _allBufsSize -= bytesToPull;
      bytesRemaining -= bytesToPull;

      if (_currentBufPos == buf.length) {
        if (_debugRemoveMe) {
          print('done with buf; discard');
        }
        // TODO(erd): inefficient?
        _allBufs.removeAt(0);
        _currentBufPos = 0;
      }
    }
    return result;
  }
}
