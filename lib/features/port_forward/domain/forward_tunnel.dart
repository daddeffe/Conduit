import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class _PipeConnection {
  _PipeConnection({required this.channel, required this.socket});

  final SSHForwardChannel channel;
  final Socket socket;
  StreamSubscription<Uint8List>? channelSubscription;
  StreamSubscription<List<int>>? socketSubscription;
}

class ForwardTunnel {
  ForwardTunnel({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required SSHClient client,
  }) : _client = client;

  final int localPort;
  final String remoteHost;
  final int remotePort;
  final SSHClient _client;

  ServerSocket? _server;
  final List<_PipeConnection> _connections = [];
  StreamSubscription<Socket>? _serverSubscription;
  int _generation = 0;

  bool get isActive => _server != null;

  Future<void> start() async {
    final gen = ++_generation;

    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      localPort,
    );
    if (gen != _generation) {
      unawaited(server.close());
      return;
    }

    _server = server;
    _serverSubscription = server.listen(
      (socket) async {
        final pipeGen = gen;
        try {
          final channel =
              await _client.forwardLocal(remoteHost, remotePort);
          if (pipeGen != _generation) {
            unawaited(channel.close());
            unawaited(socket.close());
            return;
          }
          final pipe = _PipeConnection(channel: channel, socket: socket);
          _connections.add(pipe);
          _pipeBidirectional(pipe);
        } catch (_) {
          unawaited(socket.close());
        }
      },
      onError: (_) => close(),
      cancelOnError: false,
    );
  }

  void _pipeBidirectional(_PipeConnection pipe) {
    pipe.channelSubscription = pipe.channel.stream.listen(
      (data) {
        pipe.socket.add(data);
      },
      onError: (_) => _cleanupPipe(pipe),
      onDone: () => _cleanupPipe(pipe),
      cancelOnError: false,
    );
    pipe.socketSubscription = pipe.socket.listen(
      (data) {
        pipe.channel.sink.add(data);
      },
      onError: (_) => _cleanupPipe(pipe),
      onDone: () => _cleanupPipe(pipe),
      cancelOnError: false,
    );
  }

  void _cleanupPipe(_PipeConnection pipe) {
    unawaited(pipe.channelSubscription?.cancel() ?? Future<void>.value());
    unawaited(pipe.socketSubscription?.cancel() ?? Future<void>.value());
    unawaited(pipe.channel.close());
    unawaited(pipe.socket.close());
    _connections.remove(pipe);
  }

  Future<void> close() async {
    _generation += 1;
    _serverSubscription?.cancel();
    _serverSubscription = null;

    await _server?.close();
    _server = null;

    for (final pipe in List.of(_connections)) {
      _cleanupPipe(pipe);
    }
    _connections.clear();
  }
}
