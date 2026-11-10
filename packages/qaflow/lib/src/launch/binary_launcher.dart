import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import 'launched_app.dart';
import 'prebuilt_inspector.dart';
import 'process.dart';
import 'process_tree.dart';

/// Launches a prebuilt debug or profile binary by passing engine switches
/// through the environment, the same way flutter_tools does for desktop.
/// Release binaries ignore these switches and expose no VM service.
class BinaryLauncher implements AppLauncher {
  BinaryLauncher({required this.config, ProcessStarter? processStarter, ProcessTree? processTree})
    : _start = processStarter ?? defaultProcessStarter,
      // A test's fake process has no real pid to walk or signal.
      _tree = processTree ?? (processStarter == null ? ProcessTree() : const ProcessTree.direct());

  final ProjectConfig config;
  final ProcessStarter _start;
  final ProcessTree _tree;

  static Map<String, String> engineEnvironment(int port, {Map<String, String> extra = const {}}) => {
    ...extra,
    'FLUTTER_ENGINE_SWITCHES': '3',
    'FLUTTER_ENGINE_SWITCH_1': 'enable-dart-profiling=true',
    'FLUTTER_ENGINE_SWITCH_2': 'vm-service-port=$port',
    'FLUTTER_ENGINE_SWITCH_3': 'disable-service-auth-codes=true',
  };

  /// `open` does not pass environment variables, so a .app bundle is run
  /// through its Contents/MacOS executable.
  static String resolveExecutable(
    String binaryPath, {
    required bool isMacOS,
    ProcessResult Function(List<String> arguments)? runPlutil,
  }) {
    if (!isMacOS || !binaryPath.endsWith('.app')) return binaryPath;
    final plistPath = p.join(binaryPath, 'Contents', 'Info.plist');
    final run = runPlutil ?? (args) => Process.runSync('/usr/bin/plutil', args);
    // `plutil -extract ... raw` (rather than a raw file read + regex)
    // transparently handles both XML and Xcode's default binary-format
    // Info.plist, and reports a missing file or a missing key the same
    // way: a non-zero exit with a message on stderr.
    final result = run(['-extract', 'CFBundleExecutable', 'raw', '-o', '-', plistPath]);
    final name = result.stdout.toString().trim();
    if (result.exitCode != 0 || name.isEmpty) {
      final reason = result.stderr.toString().trim();
      throw LaunchException(
        'could not read CFBundleExecutable from $binaryPath (checked Contents/Info.plist)'
        '${reason.isEmpty ? '' : ': $reason'}',
      );
    }
    return p.join(binaryPath, 'Contents', 'MacOS', name);
  }

  static Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  @override
  Future<LaunchedApp> start() async {
    // A release build would only fail once the 30 s connect timeout ran out.
    // A missing agent is not refused: an obfuscated build can hide the marker.
    final info = inspectPrebuiltApp(config.binary!);
    if (info.isRelease) throw LaunchException(info.problem!);
    final port = await freePort();
    final executable = resolveExecutable(config.binary!, isMacOS: Platform.isMacOS);
    final process = await _start(
      executable,
      const [],
      environment: {
        ...Platform.environment,
        ...engineEnvironment(port, extra: config.env),
      },
    );
    liveProcesses.track(process, _tree);

    final logs = StreamController<String>.broadcast();
    // logs.close() must wait for both stdout and stderr onDone (which the
    // Stream contract fires strictly after all of that stream's data
    // events), otherwise a line still working its way through the
    // utf8/LineSplitter transform pipeline when the process exits can
    // arrive after close and crash the controller. See
    // FlutterRunLauncher.start for the same pattern.
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(logs.add, onDone: stdoutDone.complete);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(logs.add, onDone: stderrDone.complete);
    unawaited(Future.wait([stdoutDone.future, stderrDone.future]).then((_) => logs.close()));

    return LaunchedApp(
      appId: null,
      wsUri: Uri.parse('ws://127.0.0.1:$port/ws'),
      mode: config.mode.name,
      supportsRestart: false,
      logs: logs.stream,
      exitCode: process.exitCode,
      onStop: () => _tree.kill(process),
    );
  }
}
