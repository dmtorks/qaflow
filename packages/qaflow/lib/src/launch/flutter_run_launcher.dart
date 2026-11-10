import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/project_config.dart';
import 'daemon_protocol.dart';
import 'flutter_sdk.dart';
import 'launched_app.dart';
import 'process.dart';
import 'process_tree.dart';

/// Launches a source project with `flutter run --machine` and drives the
/// daemon protocol over stdin/stdout.
class FlutterRunLauncher implements AppLauncher {
  FlutterRunLauncher({
    required this.config,
    required this.sdk,
    ProcessStarter? processStarter,
    this.startTimeout = const Duration(minutes: 5),
    this.stopTimeout = const Duration(seconds: 10),
    this.deviceId,
    ProcessTree? processTree,
  }) : _start = processStarter ?? defaultProcessStarter,
       // A test's fake process has no real pid to walk or signal.
       _tree = processTree ?? (processStarter == null ? ProcessTree() : const ProcessTree.direct());

  final ProjectConfig config;
  final FlutterSdk sdk;
  final ProcessStarter _start;
  final ProcessTree _tree;

  /// The resolved device (a simulator UDID, an emulator serial); defaults to config.device.
  final String? deviceId;
  final Duration startTimeout;

  /// Bound on how long a shutdown step (app.stop response, or process exit
  /// after stdin closes) is given before the process is force-killed.
  final Duration stopTimeout;

  List<String> get arguments => [
    'run',
    '--machine',
    '-d',
    deviceId ?? config.device,
    '--${config.mode.name}',
    '-t',
    config.entrypoint,
    if (config.flavor != null) ...['--flavor', config.flavor!],
    for (final d in config.dartDefines.entries) '--dart-define=${d.key}=${d.value}',
  ];

  @override
  Future<LaunchedApp> start() async {
    final process = await _start(
      sdk.executable,
      arguments,
      workingDirectory: config.source,
      environment: {...Platform.environment, ...config.env},
      runInShell: sdk.runInShell,
    );
    liveProcesses.track(process, _tree);

    final logs = StreamController<String>.broadcast();
    // Last 20 lines of non-frame stdout, stderr, app.log and
    // daemon.logMessage output, so an early-exit LaunchException can quote
    // what the process actually printed (spec 8.4).
    final tail = <String>[];
    void addLog(String line) {
      tail.add(line);
      if (tail.length > 20) tail.removeAt(0);
      logs.add(line);
    }

    final appStart = Completer<DaemonMessage>();
    final debugPort = Completer<DaemonMessage>();
    final started = Completer<void>();
    // appStart is awaited immediately below, so it already has a listener by
    // the time any failure can complete it. debugPort and started are only
    // awaited later (after appStart resolves), so an early failure would
    // complete them with no listener attached yet, which Dart reports as an
    // uncaught zone error. Mark them handled up front; a later `await` still
    // observes their value or error normally, this only silences the
    // zone-level "nobody's listening" report.
    debugPort.future.ignore();
    started.future.ignore();
    final pending = <int, Completer<DaemonMessage>>{};
    var nextId = 1;

    void failStart(Object error) {
      if (!appStart.isCompleted) appStart.completeError(error);
      if (!debugPort.isCompleted) debugPort.completeError(error);
      if (!started.isCompleted) started.completeError(error);
    }

    // logs.close() must wait for both of these (their onDone, which the
    // Stream contract fires strictly after all of that stream's data
    // events) before it runs, otherwise a line still working its way
    // through the utf8/LineSplitter transform pipeline when the process
    // exits can arrive after close and crash the controller. Once close is
    // gated this way, nothing can call addLog() after it — both listeners
    // below are the only writers, and both stop producing data before their
    // own onDone fires.
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final message = DaemonProtocol.parseLine(line);
      if (message == null) {
        if (line.trim().isNotEmpty) addLog(line);
        return;
      }
      if (message.id != null) {
        pending.remove(message.id)?.complete(message);
        return;
      }
      switch (message.event) {
        case 'app.start':
          if (!appStart.isCompleted) appStart.complete(message);
        case 'app.debugPort':
          if (!debugPort.isCompleted) debugPort.complete(message);
        case 'app.started':
          if (!started.isCompleted) started.complete();
        case 'app.log':
          addLog(message.params['log']?.toString() ?? '');
        case 'daemon.logMessage':
          addLog('[daemon] ${message.params['message']}');
        case 'app.stop':
          failStart(LaunchException('app stopped before it started: ${message.params['error']}'));
        default:
        // Unknown/unhandled events (app.progress, app.devTools, app.dtd,
        // ...) are ignored; the daemon protocol is expected to grow more
        // of these over time.
      }
    }, onDone: stdoutDone.complete);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(addLog, onDone: stderrDone.complete);
    unawaited(
      process.exitCode.then((code) async {
        await Future.wait([stdoutDone.future, stderrDone.future]);
        final lastOutput = tail.isEmpty ? '' : '\nLast output:\n${tail.join('\n')}';
        failStart(LaunchException('flutter run exited with code $code before the app started.$lastOutput'));
        logs.close();
      }),
    );

    Future<DaemonMessage> request(String method, Map<String, Object?> params) {
      final id = nextId++;
      final completer = Completer<DaemonMessage>();
      pending[id] = completer;
      process.stdin.write(DaemonProtocol.encodeRequest(id, method, params));
      return completer.future;
    }

    try {
      final startMessage = await appStart.future.timeout(
        startTimeout,
        onTimeout: () => throw LaunchException('no app.start within $startTimeout'),
      );
      final appId = startMessage.params['appId'] as String;
      final portMessage = await debugPort.future.timeout(
        startTimeout,
        onTimeout: () => throw LaunchException('no app.debugPort within $startTimeout'),
      );
      await started.future.timeout(
        startTimeout,
        onTimeout: () => throw LaunchException('no app.started within $startTimeout'),
      );

      return LaunchedApp(
        appId: appId,
        wsUri: Uri.parse(portMessage.params['wsUri'] as String),
        mode: startMessage.params['mode'] as String? ?? config.mode.name,
        supportsRestart: startMessage.params['supportsRestart'] == true,
        logs: logs.stream,
        exitCode: process.exitCode,
        onStop: () => _shutDown(
          process,
          graceful: () async {
            try {
              await request('app.stop', {'appId': appId}).timeout(stopTimeout);
            } catch (_) {
              // Fall through to closing stdin, which also shuts the daemon down.
            }
          },
        ),
        onRestart: () async {
          final DaemonMessage response;
          try {
            response = await request('app.restart', {'appId': appId, 'fullRestart': true}).timeout(startTimeout);
          } on TimeoutException {
            throw LaunchException('hot restart did not finish within $startTimeout');
          }
          if (response.error != null) {
            throw LaunchException('hot restart failed: ${response.error}');
          }
          // The daemon serialises an OperationResult as {code, message};
          // a non-zero code is a failed restart (e.g. a compile error).
          final result = response.result;
          if (result is Map && result['code'] is int && result['code'] != 0) {
            throw LaunchException('hot restart failed: ${result['message']}');
          }
        },
      );
    } catch (_) {
      // Startup failed (timeout, early exit, or an app.stop event): the
      // spawned flutter run process would otherwise be orphaned, since
      // nothing holds a LaunchedApp to call onStop on. Close stdin (a clean
      // daemon shutdown) and force-kill if it does not exit in time.
      await _shutDown(process);
      rethrow;
    }
  }

  /// Runs [graceful], then closes stdin (a clean daemon shutdown) and waits
  /// for exit, killing the whole process tree if it does not exit within
  /// [stopTimeout]. The app is recorded first: if flutter run exits but
  /// leaves it running, it is killed too rather than orphaned.
  Future<void> _shutDown(Process process, {Future<void> Function()? graceful}) async {
    final below = await _tree.descendants(process.pid);
    await graceful?.call();
    try {
      await process.stdin.close().timeout(stopTimeout);
    } catch (_) {}
    try {
      await process.exitCode.timeout(stopTimeout);
    } on TimeoutException {
      // During an Android build the tree includes the Gradle daemon, which
      // this stops too. That is intended: the launch is being cancelled.
      await _tree.kill(process);
    } catch (_) {}
    await _tree.killSurvivors(below);
  }
}
