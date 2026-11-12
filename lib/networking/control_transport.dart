import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A bounded JSON control channel. Audio never travels through this channel.
class ControlConnection {
  ControlConnection(this.socket, {required this.address});
  final WebSocket socket;
  final String address;
  String? deviceId;
  bool accepted = false;
  bool closed = false;
  bool _closing = false;
  final Stopwatch lastReceived = Stopwatch()..start();
  StreamSubscription<dynamic>? _subscription;

  void listen(
    void Function(Map<String, dynamic>) onMessage,
    void Function() onClose,
  ) {
    _subscription = socket.listen(
      (dynamic payload) {
        try {
          if (payload is! String || payload.length > 65536) {
            throw const FormatException('Invalid control message size');
          }
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic> ||
              decoded['v'] != 1 ||
              decoded['type'] is! String) {
            throw const FormatException('Unsupported control protocol');
          }
          lastReceived.reset();
          onMessage(decoded);
        } catch (_) {
          unawaited(close(WebSocketStatus.policyViolation));
        }
      },
      onError: (Object error) {
        if (!closed) {
          closed = true;
          onClose();
        }
      },
      onDone: () {
        if (!closed) {
          closed = true;
          onClose();
        }
      },
      cancelOnError: true,
    );
  }

  void send(String type, Map<String, Object?> payload) {
    if (!closed && !_closing && socket.readyState == WebSocket.open) {
      try {
        socket.add(jsonEncode({'v': 1, 'type': type, ...payload}));
      } on StateError {
        // The Dart sink can close before readyState reflects the close frame.
        _closing = true;
        unawaited(socket.close());
      }
    }
  }

  Future<void> close([int code = WebSocketStatus.normalClosure]) async {
    if (closed || _closing) return;
    _closing = true;
    await socket.close(code);
  }

  Future<void> dispose() async {
    closed = true;
    _closing = true;
    // Flush queued STOP/HANDOVER frames before cancelling the receive stream.
    // Cancelling a WebSocket subscription first can abort the underlying socket.
    await socket.close();
    await _subscription?.cancel();
  }
}

class ControlServer {
  HttpServer? _server;
  int get port => _server?.port ?? 0;

  Future<void> start({
    required int port,
    required void Function(ControlConnection) onConnection,
  }) async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen((request) async {
      if (request.uri.path != '/heming' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      try {
        final address = request.connectionInfo?.remoteAddress.address ?? '';
        final socket = await WebSocketTransformer.upgrade(request);
        socket.pingInterval = const Duration(seconds: 3);
        onConnection(ControlConnection(socket, address: address));
      } catch (_) {
        // The remote can disappear during the HTTP upgrade.
      }
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  static Future<ControlConnection> connect(String host, int port) async {
    final addresses = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      throw const SocketException('No IPv4 address for host');
    }
    final address = addresses.first.address;
    final uri = Uri(scheme: 'ws', host: address, port: port, path: '/heming');
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 5));
    socket.pingInterval = const Duration(seconds: 3);
    return ControlConnection(socket, address: address);
  }
}
