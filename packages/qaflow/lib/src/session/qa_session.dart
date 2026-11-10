import 'dart:async';
import 'dart:io';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../config/project_config.dart';
import '../device/device.dart';
import '../device/device_manager.dart';
import '../driver/qa_driver.dart';
import '../driver/vm_connection.dart';
import '../flow/app_session.dart';
import '../launch/binary_launcher.dart';
import '../launch/flutter_run_launcher.dart';
import '../launch/flutter_sdk.dart';
import '../launch/launched_app.dart';
import '../launch/process.dart';
import '../remote/remote_devices.dart';
import '../remote/remote_host.dart';
import '../remote/remote_launcher.dart';

/// Opens a control connection to a `qa host`. [RemoteHost.connect] in
/// production; injectable for tests.
typedef HostConnector = Future<RemoteHost> Function(Uri url, String token);

/// The session's link to its `qa host`. [stop] closes it and the next start
/// opens a new one.
class _HostLink {
  _HostLink(this._connect, this.host);
  final Future<RemoteHost> Function() _connect;
  RemoteHost? host;

  bool get lost => host?.isClosed ?? true;

  /// Apps launched over this link that the host may still be running.
  final launched = <String>{};

  Future<RemoteHost> connected() async {
    if (!lost) return host!;
    final open = host = await _connect();
    // Within its grace period the host hands a new connection the apps the
    // last one launched. Stop them, or a relaunch would run a second copy.
    final stale = [...launched];
    launched.clear();
    for (final appId in stale) {
      try {
        await open.call('app.stop', {'appId': appId});
      } catch (_) {
        // Already stopped, or the grace period ended first.
      }
    }
    return open;
  }

  Future<void> close() async {
    final open = host;
    host = null;
    await open?.close();
  }
}

/// A launched app plus a connected driver. Owns teardown, and can hot
/// restart or relaunch the app between flows.
class QaSession implements AppSession {
  QaSession._(
    this.config,
    this._launcherFor,
    this._devices,
    this._connector,
    this._emit,
    this._screenshotDirectory,
    Duration? agentTimeout,
    this._host,
  ) : agentTimeout = agentTimeout ?? defaultAgentTimeout;

  final ProjectConfig config;
  final AppLauncher Function(String deviceId) _launcherFor;
  final Devices _devices;

  /// Set when [ProjectConfig.host] is: devices and launches then go there.
  final _HostLink? _host;
  AppLauncher? _launcher;
  ReadyDevice? _ready;
  Future<ReadyDevice>? _preparing;
  CancelSignal? _cancel;
  final VmConnector? _connector;
  final void Function(String) _emit;
  final String? _screenshotDirectory;
  final StreamController<String> _logs = StreamController<String>.broadcast();

  LaunchedApp? _app;
  VmConnection? _connection;
  QaDriver? _driver;

  /// How long [reset] waits for the agent to answer in the new isolate
  /// after a hot restart, and for `waitForIdle` to stop answering
  /// `not_ready` while the window is briefly hidden.
  static const Duration defaultAgentTimeout = Duration(seconds: 30);

  /// Overridable in tests; defaults to [defaultAgentTimeout].
  final Duration agentTimeout;

  /// The environment variable `qa` reads the host token from.
  static const String hostTokenVariable = 'QA_HOST_TOKEN';

  static const String missingHostTokenMessage = 'Set $hostTokenVariable to the token qa host printed';

  /// Validates [config] and prepares a launcher without launching.
  ///
  /// With a [ProjectConfig.host] it connects to that host with [hostToken],
  /// or else the token in [environment]'s `QA_HOST_TOKEN` (default: the
  /// process environment; QAFlow Studio passes [hostToken] instead), and
  /// runs devices and launches there; no local Flutter SDK is needed, and
  /// [devices] is not used. A config with no device given runs on the
  /// host's desktop, not this machine's.
  static Future<QaSession> create(
    ProjectConfig config, {
    String? screenshotDirectory,
    void Function(String message)? log,
    ProcessStarter? processStarter,
    VmConnector? connector,
    AppLauncher? launcher,
    Duration? agentTimeout,
    Devices? devices,
    Map<String, String>? environment,
    HostConnector? connectHost,
    String? hostToken,
  }) async {
    final errors = config.validate();
    if (errors.isNotEmpty) throw ArgumentError('invalid project config: ${errors.join('; ')}');
    if (config.host case final remote?) {
      final token = hostToken ?? (environment ?? Platform.environment)[hostTokenVariable];
      if (token == null || token.trim().isEmpty) throw RemoteHostException(missingHostTokenMessage);
      final connect = connectHost ?? RemoteHost.connect;
      final link = _HostLink(() => connect(remote.url, token.trim()), null);
      final host = await link.connected();
      log?.call('using the QA host at ${remote.url} (${host.os} ${host.osVersion ?? ''})'.trimRight());
      final onHost = config.deviceIsDefault ? config.withDevice(host.os) : config;
      final hostErrors = onHost.validate();
      if (hostErrors.isNotEmpty) {
        await link.close();
        throw ArgumentError('invalid project config: ${hostErrors.join('; ')}');
      }
      return QaSession._(
        onHost,
        (flutterId) =>
            launcher ??
            RemoteLauncher(
              link.host!,
              remote.url,
              token.trim(),
              onHost,
              remote.project,
              flutterId,
              onLaunched: link.launched.add,
              onStopped: link.launched.remove,
            ),
        RemoteDevices(host),
        connector,
        log ?? ((_) {}),
        screenshotDirectory,
        agentTimeout,
        link,
      );
    }
    final sdk = launcher == null && config.binary == null
        ? await FlutterSdk.locate(explicitPath: config.flutterPath)
        : null;
    AppLauncher launcherFor(String deviceId) =>
        launcher ??
        (config.binary != null
            ? BinaryLauncher(config: config, processStarter: processStarter)
            : FlutterRunLauncher(config: config, sdk: sdk!, processStarter: processStarter, deviceId: deviceId));
    return QaSession._(
      config,
      launcherFor,
      devices ?? DeviceManager(),
      connector,
      log ?? ((_) {}),
      screenshotDirectory,
      agentTimeout,
      null,
    );
  }

  /// [create] followed by [start].
  static Future<QaSession> launch(
    ProjectConfig config, {
    String? screenshotDirectory,
    void Function(String message)? log,
    ProcessStarter? processStarter,
    VmConnector? connector,
    AppLauncher? launcher,
    Duration? agentTimeout,
    Devices? devices,
    Map<String, String>? environment,
    HostConnector? connectHost,
    String? hostToken,
  }) async {
    final session = await create(
      config,
      screenshotDirectory: screenshotDirectory,
      log: log,
      processStarter: processStarter,
      connector: connector,
      launcher: launcher,
      agentTimeout: agentTimeout,
      devices: devices,
      environment: environment,
      connectHost: connectHost,
      hostToken: hostToken,
    );
    try {
      await session.start();
    } catch (_) {
      // Closes a host connection the failed start leaves open.
      await session.stop().catchError((Object _) {});
      rethrow;
    }
    return session;
  }

  LaunchedApp get app => _app ?? (throw StateError('the app is not running'));

  @override
  QaDriver get driver => _driver ?? (throw StateError('the app is not running'));

  @override
  bool get isRunning => _app != null;

  @override
  bool get supportsHotRestart => _app?.supportsRestart ?? false;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  DeviceInfo? get device => _ready?.info;

  @override
  DeviceController get deviceController =>
      _ready?.controller ?? UnsupportedDeviceController(DeviceTarget.parse(config.device).platform);

  @override
  Future<DeviceInfo> prepareDevice({void Function(DeviceInfo device)? onBooting}) async {
    // A device resolved over a host connection that has since closed is
    // resolved again over a new one.
    if (_host?.lost ?? false) _preparing = null;
    final ready = await (_preparing ??= _resolve(onBooting));
    return ready.info;
  }

  Future<ReadyDevice> _resolve(void Function(DeviceInfo device)? onBooting) async {
    final cancel = _cancel = CancelSignal();
    try {
      final host = _host;
      final devices = host == null ? _devices : RemoteDevices(await host.connected());
      final ready = await devices.resolve(
        DeviceTarget.parse(config.device),
        onBooting: (d) {
          _emit('booting ${d.title}');
          onBooting?.call(d);
        },
        cancel: cancel,
      );
      _ready = ready;
      _launcher = _launcherFor(ready.flutterId);
      return ready;
    } catch (_) {
      _preparing = null; // a later start may try again
      rethrow;
    } finally {
      _cancel = null;
    }
  }

  @override
  Future<void> start() async {
    if (_app != null) return;
    await prepareDevice();
    _emit('launching ${config.name} (${config.mode.name}, ${device?.title ?? config.device})');
    final app = await _launcher!.start();

    // Last 20 app log lines and the exit code once the process dies, so a
    // connect failure caused by the app crashing on start is reported with
    // what actually happened. Registered before the connect call so this
    // listener on exitCode runs before VmConnection.connect's own.
    final logTail = <String>[];
    app.logs.listen((line) {
      logTail.add(line);
      if (logTail.length > 20) logTail.removeAt(0);
      _emit('[app] $line');
      _logs.add(line);
    });
    int? appExitCode;
    unawaited(
      app.exitCode.then((code) {
        appExitCode = code;
        _emit('[app] exited with code $code');
      }),
    );

    VmConnection? connection;
    try {
      _emit('connecting to ${redactUri(app.wsUri)}');
      try {
        connection = await VmConnection.connect(app.wsUri, connector: _connector, giveUpWhen: app.exitCode);
      } catch (_) {
        final code = appExitCode;
        if (code != null) {
          final tail = logTail.isEmpty ? '' : '\nLast output:\n${logTail.join('\n')}';
          throw LaunchException('the app process exited with code $code before the VM service connected.$tail');
        }
        rethrow;
      }
      connection.logs.listen((line) => _emit('[vm] $line'));
      final driver = QaDriver(
        connection,
        log: _emit,
        screenshotDirectory: _screenshotDirectory,
        inlineScreenshotsOnly: _host != null,
      );
      final pong = await driver.ping(screenshotDirectory: _agentScreenshotDirectory);
      if (pong.v != protocolVersion) {
        throw LaunchException('agent protocol v${pong.v} does not match driver protocol v$protocolVersion');
      }
      final target = DeviceTarget.parse(config.device).platform;
      final reported = pong.result?['platform'] as String? ?? '';
      if (target.isMobile && reported.toLowerCase() != target.label.toLowerCase()) {
        throw LaunchException('expected an ${target.label} app but the agent reports $reported');
      }
      _emit('agent ready: ${pong.result}');
      _app = app;
      _connection = connection;
      _driver = driver;
    } catch (_) {
      // connection is only non-null once VmConnection.connect succeeded, so
      // this disposes it exactly once for any failure after that point
      // (protocol mismatch, a ping QaException, ...). Nothing has disposed
      // it yet on this path, unlike the success path where QaSession.stop()
      // owns that.
      try {
        if (connection != null) await connection.dispose();
      } finally {
        await app.stop();
      }
      rethrow;
    }
  }

  @override
  Future<void> reset({bool clearState = false}) async {
    if (_app == null) {
      await start();
      if (!clearState) return;
    }
    if (clearState) await driver.resetState();
    if (supportsHotRestart) {
      _emit('hot restarting');
      await app.restart();
      await _awaitAgent();
    } else {
      _emit('relaunching');
      await _stopApp();
      await start();
    }
    // A window that is briefly hidden (minimized, fully covered, switching
    // Spaces) makes the agent answer not_ready here too, same as _awaitAgent
    // above; retry it on the same deadline instead of letting it escape as
    // an infrastructure error and end the whole run.
    await _retryNotReady(() async {
      await driver.waitForIdle();
    });
  }

  /// After a hot restart the agent re-registers in a new isolate; calls
  /// answer not_ready until it has.
  Future<void> _awaitAgent() => _retryNotReady(() async {
    await driver.ping(screenshotDirectory: _agentScreenshotDirectory);
  });

  /// Where the agent writes `file` screenshots. Not sent to an app on a
  /// host: this machine's folder means nothing there.
  String? get _agentScreenshotDirectory => _host == null ? _screenshotDirectory : null;

  /// Retries [attempt] against `not_ready` until [agentTimeout] (default
  /// 30 s), polling every 250 ms, then rethrows.
  Future<void> _retryNotReady(Future<void> Function() attempt) async {
    final deadline = DateTime.now().add(agentTimeout);
    while (true) {
      try {
        await attempt();
        return;
      } on QaException catch (e) {
        if (e.code != QaErrorCode.notReady || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// Stops the app and closes the host connection, if any; a later [start]
  /// opens a new one.
  @override
  Future<void> stop() async {
    final host = _host;
    if (host == null) return _stopApp();
    try {
      await _stopApp();
    } finally {
      await host.close();
    }
  }

  Future<void> _stopApp() async {
    _cancel?.cancel();
    final app = _app;
    final connection = _connection;
    _app = null;
    _connection = null;
    _driver = null;
    if (app == null) return;
    try {
      await connection?.dispose();
    } finally {
      await app.stop();
    }
  }
}
