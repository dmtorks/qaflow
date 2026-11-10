import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../config/project_config.dart';
import '../device/android_devices.dart';
import '../device/device.dart';
import '../device/device_manager.dart';
import '../driver/qa_driver.dart';
import '../driver/transport.dart';
import '../launch/binary_launcher.dart';
import '../launch/flutter_run_launcher.dart';
import '../launch/flutter_sdk.dart';
import '../launch/launched_app.dart';
import 'host_protocol.dart';

/// Reads the host token from [path], or generates one (32 random bytes as
/// hex) and writes it there, readable by the owner only where the platform
/// supports it. [onGenerated] is called when a new token was written.
String loadOrCreateHostToken(String path, {void Function(String token)? onGenerated}) {
  final file = File(path);
  if (file.existsSync()) {
    final existing = file.readAsStringSync().trim();
    if (existing.isNotEmpty) {
      // A file someone else could read was copied in or made by hand.
      if (!Platform.isWindows && file.statSync().mode & 0x3f != 0) _chmod('600', path);
      return existing;
    }
  }
  final random = Random.secure();
  final token = [for (var i = 0; i < 32; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  final dir = file.parent;
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    if (!Platform.isWindows) _chmod('700', dir.path);
  }
  // Restricted while still empty and only then renamed into place, so the
  // token is never in a file others can read.
  final temp = File(p.join(dir.path, '.${p.basename(path)}.${random.nextInt(1 << 32)}.tmp'));
  try {
    temp.writeAsStringSync('');
    if (!Platform.isWindows) _chmod('600', temp.path);
    temp.writeAsStringSync('$token\n', flush: true);
    temp.renameSync(path);
  } catch (_) {
    if (temp.existsSync()) temp.deleteSync();
    rethrow;
  }
  onGenerated?.call(token);
  return token;
}

void _chmod(String mode, String path) {
  final result = Process.runSync('chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw FileSystemException('could not restrict permissions: ${result.stderr.toString().trim()}', path);
  }
}

/// The `qa host` daemon: launches apps and boots devices for one remote
/// client at a time over an authenticated loopback WebSocket.
class HostServer {
  HostServer._(this._server, this._token, this._devices, this._launcherFor, this._disconnectGrace, this._pingInterval);

  static Future<HostServer> start({
    int port = 7777,
    required String token,
    Devices? devices,
    AppLauncher Function(ProjectConfig config, String flutterId)? launcherFor,
    Duration disconnectGrace = const Duration(seconds: 10),
    Duration pingInterval = const Duration(seconds: 5),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final host = HostServer._(server, token, devices ?? DeviceManager(), launcherFor, disconnectGrace, pingInterval);
    server.listen((request) => unawaited(host._handle(request)));
    return host;
  }

  final HttpServer _server;
  final String _token;
  final Devices _devices;
  final AppLauncher Function(ProjectConfig config, String flutterId)? _launcherFor;
  final Duration _disconnectGrace;

  /// How often each socket is pinged. A peer that misses a pong is closed,
  /// so a half-open connection (a client that dropped off the network while
  /// the tunnel's end stayed up) does not hold the client lock for ever.
  final Duration _pingInterval;

  _ControlConnection? _client;
  Timer? _graceTimer;
  var _nextAppId = 1;
  final Map<String, LaunchedApp> _apps = {};
  final Map<String, StreamSubscription<String>> _appLogs = {};
  final Map<String, ReadyDevice> _readyDevices = {};
  Future<FlutterSdk>? _sdk;
  static const _logDrain = Duration(seconds: 2);
  final Set<WebSocket> _proxies = {};
  var _closed = false;

  int get port => _server.port;

  /// The running apps by the appId the host gave them. Each keeps its
  /// internal VM-service URI, which never leaves the host.
  Map<String, LaunchedApp> get launchedApps => UnmodifiableMapView(_apps);

  /// Stops serving, closes the client and stops every app.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _graceTimer?.cancel();
    _graceTimer = null;
    await _server.close(force: true);
    final client = _client;
    _client = null;
    client?.cancelPending();
    await client?.socket.close();
    await Future.wait([for (final socket in _proxies.toList()) socket.close()]);
    _proxies.clear();
    await _stopAll();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (!_authorized(request.uri.queryParameters['token'])) {
        return await _refuse(request, HttpStatus.unauthorized);
      }
      final segments = request.uri.pathSegments;
      if (segments.length == 1 && segments.single == 'control') return await _acceptControl(request);
      if (segments.length == 2 && segments.first == 'vm') return await _proxyVmService(request, segments.last);
      await _refuse(request, HttpStatus.notFound);
    } catch (_) {
      // A client that went away mid-handshake; nothing to answer.
    }
  }

  /// Compares every byte whatever the first difference, so the time taken
  /// says nothing about how much of a guess was right.
  bool _authorized(String? given) {
    if (given == null) return false;
    final a = utf8.encode(given);
    final b = utf8.encode(_token);
    var diff = a.length ^ b.length;
    for (var i = 0; i < b.length; i++) {
      diff |= (i < a.length ? a[i] : 0) ^ b[i];
    }
    return diff == 0;
  }

  Future<void> _refuse(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  Future<void> _acceptControl(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) return _refuse(request, HttpStatus.badRequest);
    final socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = _pingInterval;
    if (_client != null || _closed) {
      await socket.close(hostInUseCloseCode, hostInUseMessage);
      return;
    }
    final connection = _client = _ControlConnection(socket);
    _graceTimer?.cancel();
    _graceTimer = null;
    socket.listen(
      (data) {
        if (data is String) _onMessage(connection, data);
      },
      onDone: () => _onDisconnect(connection),
      onError: (Object _) => _onDisconnect(connection),
      cancelOnError: true,
    );
  }

  /// Joins the client to [appId]'s VM service frame for frame. The client
  /// only ever sees `/vm/<appId>`; the internal URI, with its auth code,
  /// stays here.
  Future<void> _proxyVmService(HttpRequest request, String appId) async {
    final app = _apps[appId];
    if (app == null) return _refuse(request, HttpStatus.notFound);
    if (!WebSocketTransformer.isUpgradeRequest(request)) return _refuse(request, HttpStatus.badRequest);
    final WebSocket upstream;
    try {
      upstream = await WebSocket.connect(app.wsUri.toString());
      upstream.pingInterval = _pingInterval;
    } catch (_) {
      return _refuse(request, HttpStatus.badGateway);
    }
    final WebSocket client;
    try {
      client = await WebSocketTransformer.upgrade(request);
      client.pingInterval = _pingInterval;
    } catch (_) {
      await upstream.close();
      rethrow;
    }
    _proxies.addAll([client, upstream]);
    void pipe(WebSocket from, WebSocket to) => from.listen(
      (frame) {
        if (to.readyState == WebSocket.open) to.add(frame);
      },
      onDone: () {
        _proxies.remove(from);
        unawaited(to.close(_forwardableCloseCode(from.closeCode), from.closeReason));
      },
      onError: (Object _) {
        _proxies.remove(from);
        unawaited(from.close());
        unawaited(to.close());
      },
      cancelOnError: true,
    );
    pipe(client, upstream);
    pipe(upstream, client);
  }

  /// Codes 1005, 1006 and 1015 describe a close and may not be sent in one.
  static int? _forwardableCloseCode(int? code) =>
      code == null || code == 1005 || code == 1006 || code == 1015 ? null : code;

  void _onDisconnect(_ControlConnection connection) {
    if (!identical(_client, connection)) return;
    _client = null;
    connection.cancelPending();
    if (_closed) return;
    _graceTimer?.cancel();
    _graceTimer = Timer(_disconnectGrace, () {
      _graceTimer = null;
      unawaited(_stopAll());
    });
  }

  /// No client, and none can still claim the apps.
  bool get _abandoned => _client == null && _graceTimer == null;

  void _onMessage(_ControlConnection connection, String text) {
    final HostMessage message;
    try {
      message = HostMessage.decode(text);
    } on FormatException {
      return; // Without an id there is no one to answer.
    }
    if (message is! HostRequest) return;
    unawaited(_answer(connection, message));
  }

  Future<void> _answer(_ControlConnection connection, HostRequest request) async {
    HostResponse response;
    try {
      response = HostResponse.success(request.id, await _dispatch(connection, request.method, request.params));
    } on HostError catch (e) {
      response = HostResponse.failure(request.id, e);
    } on LaunchException catch (e) {
      response = HostResponse.failure(request.id, HostError(HostError.launchFailed, e.message));
    } on DeviceToolException catch (e) {
      response = HostResponse.failure(request.id, HostError(HostError.launchFailed, e.message));
    } on QaException catch (e) {
      response = HostResponse.failure(
        request.id,
        HostError(HostError.launchFailed, e.message, {'qaCode': e.code.name}),
      );
    } on FormatException catch (e) {
      response = HostResponse.failure(request.id, HostError(HostError.invalidParams, e.message));
    } on TypeError catch (e) {
      response = HostResponse.failure(request.id, HostError(HostError.invalidParams, 'bad params: $e'));
    } on ArgumentError catch (e) {
      response = HostResponse.failure(request.id, HostError(HostError.invalidParams, '${e.message}'));
    } catch (e) {
      response = HostResponse.failure(request.id, HostError(HostError.internalError, '$e'));
    }
    connection.send(response);
  }

  Future<Map<String, Object?>> _dispatch(
    _ControlConnection connection,
    String method,
    Map<String, Object?> params,
  ) async => switch (method) {
    'hello' => _hello(params),
    'devices.list' => await _listDevices(),
    'devices.resolve' => await _resolveDevice(connection, params),
    'app.start' => await _startApp(params),
    'app.stop' => await _stopApp(params),
    'app.restart' => await _restartApp(params),
    'device.setOrientation' => await _setOrientation(params),
    'device.resetOrientation' => await _resetOrientation(params),
    'device.openLink' => await _openLink(params),
    _ => throw HostError(HostError.methodNotFound, 'unknown method $method'),
  };

  Map<String, Object?> _hello(Map<String, Object?> params) {
    final client = params['protocol'];
    if (client != hostProtocolVersion) {
      throw HostError(
        HostError.protocolMismatch,
        protocolMismatchMessage(host: hostProtocolVersion, client: client is int ? client : 0),
      );
    }
    return {
      'protocol': hostProtocolVersion,
      'os': Platform.operatingSystem,
      'osVersion': DeviceInfo.hostVersion(Platform.operatingSystemVersion) ?? Platform.operatingSystemVersion,
      'qaVersion': qaVersion,
    };
  }

  Future<Map<String, Object?>> _listDevices() async {
    final list = await _devices.list();
    return {
      'devices': [for (final d in list.devices) deviceInfoToWire(d)],
      'problems': [
        for (final problem in list.problems) {'platform': problem.platform.name, 'message': problem.message},
      ],
    };
  }

  Future<Map<String, Object?>> _resolveDevice(_ControlConnection connection, Map<String, Object?> params) async {
    final target = DeviceTarget.parse(params['device'] as String);
    final cancel = CancelSignal();
    connection.pending.add(cancel);
    try {
      final ready = await _devices.resolve(
        target,
        onBooting: (info) => connection.send(HostNotification('devices.booting', {'info': deviceInfoToWire(info)})),
        cancel: cancel,
      );
      _readyDevices[ready.flutterId] = ready;
      return {'flutterId': ready.flutterId, 'info': deviceInfoToWire(ready.info)};
    } finally {
      connection.pending.remove(cancel);
    }
  }

  Future<Map<String, Object?>> _startApp(Map<String, Object?> params) async {
    final project = params['project'] as String;
    final flutterId = params['flutterId'] as String;
    final config = _projectConfig(project, (params['app'] as Map).cast<String, Object?>(), flutterId);
    final app = await _launcher(config, flutterId).start();
    if (_closed || _abandoned) {
      await app.stop();
      throw HostError(HostError.launchFailed, 'the client disconnected while the app was starting');
    }
    final appId = 'app-${_nextAppId++}';
    _apps[appId] = app;
    final logsDone = Completer<void>();
    _appLogs[appId] = app.logs.listen(
      (line) => _notify('app.log', {'appId': appId, 'line': line}),
      onDone: logsDone.complete,
    );
    unawaited(
      app.exitCode.then((code) async {
        if (identical(_apps[appId], app)) _apps.remove(appId);
        // The launchers close their logs once the process output has
        // drained; the last lines go out before the exit that ends them.
        await logsDone.future.timeout(_logDrain, onTimeout: () {});
        unawaited(_appLogs.remove(appId)?.cancel());
        _notify('app.exit', {'appId': appId, 'code': code});
      }),
    );
    return {'appId': appId, 'mode': app.mode, 'supportsRestart': app.supportsRestart};
  }

  /// The app's [ProjectConfig] with its relative paths resolved against
  /// [project], as ProjectFile resolves them against the project root.
  /// The entrypoint stays relative to the app source, as it does locally.
  ProjectConfig _projectConfig(String project, Map<String, Object?> app, String flutterId) {
    String? resolve(Object? path) => path == null ? null : p.normalize(p.join(project, path as String));
    final config = ProjectConfig(
      name: p.basename(p.normalize(project)),
      source: resolve(app['source']),
      binary: resolve(app['binary']),
      entrypoint: app['entrypoint'] as String? ?? 'lib/main_qa.dart',
      mode: BuildMode.values.byName(app['mode'] as String? ?? 'debug'),
      flavor: app['flavor'] as String?,
      dartDefines: (app['dartDefines'] as Map?)?.cast<String, String>() ?? const {},
      env: (app['env'] as Map?)?.cast<String, String>() ?? const {},
      device: _deviceFor(flutterId),
    );
    final errors = config.validate();
    if (errors.isNotEmpty) throw HostError(HostError.launchFailed, errors.join('; '));
    if (config.source case final source? when !Directory(source).existsSync()) {
      throw HostError(HostError.launchFailed, 'the app source $source does not exist on the host');
    }
    if (config.binary case final binary? when FileSystemEntity.typeSync(binary) == FileSystemEntityType.notFound) {
      throw HostError(HostError.launchFailed, 'the app binary $binary does not exist on the host');
    }
    return config;
  }

  /// The device string for [flutterId], so the config is validated for the
  /// platform it will run on.
  String _deviceFor(String flutterId) {
    if (_readyDevices[flutterId] case final ready?) {
      final info = ready.info;
      final mobile = info.platform.isMobile;
      return DeviceTarget(info.platform, mobile ? info.id : null).toString();
    }
    try {
      return DeviceTarget.parse(flutterId).toString();
    } on FormatException {
      return ProjectConfig.hostDevice;
    }
  }

  AppLauncher _launcher(ProjectConfig config, String flutterId) {
    if (_launcherFor case final factory?) return factory(config, flutterId);
    if (config.binary != null) return BinaryLauncher(config: config);
    return _LazySdkLauncher(() => _sdk ??= FlutterSdk.locate(), config, flutterId);
  }

  Future<Map<String, Object?>> _stopApp(Map<String, Object?> params) async {
    final appId = params['appId'] as String;
    final app = _apps.remove(appId);
    await app?.stop();
    return {};
  }

  Future<Map<String, Object?>> _restartApp(Map<String, Object?> params) async {
    final appId = params['appId'] as String;
    final app = _apps[appId] ?? (throw HostError(HostError.launchFailed, 'no running app $appId'));
    await app.restart();
    return {};
  }

  DeviceController _controller(Map<String, Object?> params) {
    final flutterId = params['flutterId'] as String;
    final ready =
        _readyDevices[flutterId] ??
        (throw HostError(HostError.launchFailed, 'device $flutterId has not been resolved on the host'));
    return ready.controller;
  }

  Future<Map<String, Object?>> _setOrientation(Map<String, Object?> params) async {
    final orientation = ScreenOrientation.values.byName(params['orientation'] as String);
    // The client waits for the app's views to rotate, through its own driver.
    switch (_controller(params)) {
      case final AndroidDeviceController android:
        await android.applyOrientation(orientation);
      case final controller:
        await controller.setOrientation(orientation, QaDriver(const _NoAgent()));
    }
    return {};
  }

  Future<Map<String, Object?>> _resetOrientation(Map<String, Object?> params) async {
    await _controller(params).resetOrientation();
    return {};
  }

  Future<Map<String, Object?>> _openLink(Map<String, Object?> params) async {
    await _controller(params).openLink(Uri.parse(params['link'] as String));
    return {};
  }

  void _notify(String method, Map<String, Object?> params) => _client?.send(HostNotification(method, params));

  Future<void> _stopAll() async {
    final apps = _apps.values.toList();
    _apps.clear();
    await Future.wait([for (final app in apps) app.stop().catchError((Object _) {})]);
  }
}

class _ControlConnection {
  _ControlConnection(this.socket);

  final WebSocket socket;

  /// Device boots this client is waiting on; cancelled when it goes away.
  final Set<CancelSignal> pending = {};

  void send(HostMessage message) {
    if (socket.readyState == WebSocket.open) socket.add(message.encode());
  }

  void cancelPending() {
    for (final cancel in pending.toList()) {
      cancel.cancel();
    }
  }
}

/// Locates the Flutter SDK on the first launch that needs it, so a host
/// that only runs prebuilt binaries never looks for one.
class _LazySdkLauncher implements AppLauncher {
  _LazySdkLauncher(this._sdk, this._config, this._flutterId);

  final Future<FlutterSdk> Function() _sdk;
  final ProjectConfig _config;
  final String _flutterId;

  @override
  Future<LaunchedApp> start() async =>
      FlutterRunLauncher(config: _config, sdk: await _sdk(), deviceId: _flutterId).start();
}

/// The host has no connection to the app's agent; the client rotates iOS
/// through its own driver and waits for Android's views itself, so the
/// host's controllers never call it.
class _NoAgent implements QaTransport {
  const _NoAgent();

  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) async => throw QaException(
    QaErrorCode.unsupported,
    'the QA host does not reach the app agent; the client sends ${method.name} itself',
  );
}
