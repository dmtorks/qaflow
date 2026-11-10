import 'dart:async';
import 'dart:io';

import '../launch/launched_app.dart';
import 'host_protocol.dart';

/// Why a QA host could not be used, in words for the person running qa.
class RemoteHostException implements Exception {
  RemoteHostException(this.message);
  final String message;
  @override
  String toString() => 'RemoteHostException: $message';
}

/// A control connection to a `qa host`, after a successful `hello`.
class RemoteHost {
  RemoteHost._(this.url, this._socket) {
    _socket.listen(_onFrame, onDone: _onDone, onError: (Object _) => _onDone(), cancelOnError: true);
  }

  /// Opens `/control` on [url] with [token] and checks the host's protocol.
  ///
  /// [pingInterval] lets a host that went away unnoticed (a dropped tunnel)
  /// close the connection, which fails every pending call.
  static Future<RemoteHost> connect(
    Uri url,
    String token, {
    Duration timeout = const Duration(seconds: 10),
    Duration pingInterval = const Duration(seconds: 5),
  }) async {
    final control = endpoint(url, 'control', token);
    final WebSocket socket;
    final connecting = WebSocket.connect(control.toString());
    try {
      socket = await connecting.timeout(timeout);
    } catch (e) {
      // A timeout does not cancel the connect, and a late upgrade would hold
      // the host's one-client lock with nobody using it.
      if (e is TimeoutException) unawaited(connecting.then<void>((s) => s.close(), onError: (Object _) {}));
      // dart:io carries the status only in the message text.
      if (e is WebSocketException && e.toString().contains('HTTP status code: 401')) {
        throw RemoteHostException('The QA host refused the token');
      }
      throw RemoteHostException(_unreachable(url));
    }
    socket.pingInterval = pingInterval;
    final host = RemoteHost._(url, socket);
    try {
      final hello = await host.call('hello', {'protocol': hostProtocolVersion}).timeout(timeout);
      final protocol = hello['protocol'];
      if (protocol != hostProtocolVersion) {
        throw RemoteHostException(
          protocolMismatchMessage(host: protocol is int ? protocol : 0, client: hostProtocolVersion),
        );
      }
      host
        ..os = hello['os'] as String
        ..osVersion = hello['osVersion'] as String?
        ..qaVersion = hello['qaVersion'] as String?;
      return host;
    } catch (e) {
      await host.close();
      if (e is RemoteHostException) rethrow;
      if (e is HostError) throw RemoteHostException(e.message);
      throw RemoteHostException(_unreachable(url));
    }
  }

  /// [path] on the host at [url], under any base path [url] has, with [token].
  static Uri endpoint(Uri url, String path, String token) =>
      url.replace(path: '${url.path.replaceAll(RegExp(r'/+$'), '')}/$path', queryParameters: {'token': token});

  static String _unreachable(Uri url) => "Can't reach the QA host at $url. Is the SSH tunnel open?";

  /// The URL as configured, without the token.
  final Uri url;
  final WebSocket _socket;

  /// `windows`, `macos` or `linux`.
  late final String os;

  /// `major.minor`, e.g. `10.0`.
  late final String? osVersion;
  late final String? qaVersion;

  var _nextId = 1;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _notifications = StreamController<HostNotification>.broadcast(sync: true);
  final _done = Completer<void>();

  /// Every notification from the host, delivered in order as it arrives.
  Stream<HostNotification> get notifications => _notifications.stream;

  /// The notifications named [method].
  Stream<HostNotification> on(String method) => notifications.where((n) => n.method == method);

  /// Completes when the connection has closed, from either side.
  Future<void> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Sends one request. Throws [HostError] when the host answers with an
  /// error, and [RemoteHostException] when the connection is lost first.
  Future<Map<String, Object?>> call(String method, [Map<String, Object?> params = const {}]) {
    if (isClosed) return Future.error(RemoteHostException(_lostMessage));
    final id = _nextId++;
    final completer = _pending[id] = Completer<Map<String, Object?>>();
    try {
      _socket.add(HostRequest(id, method, params).encode());
    } catch (e, stack) {
      // Params that are not JSON, or a socket closing under us.
      _pending.remove(id);
      return Future.error(e is StateError ? RemoteHostException(_lostMessage) : e, stack);
    }
    return completer.future;
  }

  /// [call], with the host's errors as [LaunchException], which sessions
  /// and Studio already report as a failed launch.
  Future<Map<String, Object?>> launchCall(String method, [Map<String, Object?> params = const {}]) async {
    try {
      return await call(method, params);
    } on HostError catch (e) {
      throw LaunchException(e.message);
    }
  }

  String get _lostMessage => _socket.closeCode == hostInUseCloseCode
      ? _socket.closeReason ?? hostInUseMessage
      : 'Lost the connection to the QA host at $url.';

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    final HostMessage message;
    try {
      message = HostMessage.decode(frame);
    } on FormatException {
      return;
    }
    switch (message) {
      case HostResponse(:final id, :final error?):
        _pending.remove(id)?.completeError(error);
      case HostResponse(:final id, :final result):
        _pending.remove(id)?.complete(result ?? const {});
      case HostNotification():
        _notifications.add(message);
      case HostRequest():
        break; // The host sends none.
    }
  }

  void _onDone() {
    if (_done.isCompleted) return;
    final lost = RemoteHostException(_lostMessage);
    for (final completer in _pending.values) {
      completer.completeError(lost);
    }
    _pending.clear();
    _done.complete();
    unawaited(_notifications.close());
  }

  Future<void> close() async {
    await _socket.close();
    _onDone();
  }
}
