import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'launched_app.dart';

/// Runs a program to completion. Injectable so tests never spawn processes.
typedef RunProcess = Future<ProcessResult> Function(String executable, List<String> arguments, {bool runInShell});

Future<ProcessResult> defaultRunProcess(String executable, List<String> arguments, {bool runInShell = false}) =>
    Process.run(executable, arguments, runInShell: runInShell);

/// Which step of [FlutterSdk.locate] found the executable.
enum FlutterSdkSource { explicit, flutterRoot, fvm, path, loginShell }

class FlutterVersion {
  const FlutterVersion({required this.frameworkVersion, required this.dartSdkVersion, required this.channel});
  final String frameworkVersion;
  final String dartSdkVersion;
  final String channel;
}

class FlutterSdk {
  FlutterSdk(this.executable, {required this.isWindows, this.source = FlutterSdkSource.explicit});

  final String executable;
  final bool isWindows;
  final FlutterSdkSource source;

  /// flutter is a .bat on Windows and must run through the shell.
  bool get runInShell => isWindows;

  static const Duration defaultLoginShellTimeout = Duration(seconds: 5);

  /// Order: explicit path, FLUTTER_ROOT, fvm default, PATH, then on macOS
  /// and Linux the user's login shell. An app started from the Dock does not
  /// inherit the terminal's PATH, but a login shell reads the same profile
  /// files the terminal does.
  static Future<FlutterSdk> locate({
    String? explicitPath,
    Map<String, String>? environment,
    bool Function(String path)? exists,
    bool? isWindows,
    RunProcess? runProcess,
    Duration loginShellTimeout = defaultLoginShellTimeout,
  }) async {
    final env = environment ?? Platform.environment;
    final fileExists = exists ?? ((path) => File(path).existsSync());
    final windows = isWindows ?? Platform.isWindows;
    final exe = windows ? 'flutter.bat' : 'flutter';
    final ctx = windows ? p.windows : p.posix;

    if (explicitPath != null) {
      if (!fileExists(explicitPath)) {
        throw LaunchException('flutter executable not found at $explicitPath');
      }
      return FlutterSdk(explicitPath, isWindows: windows);
    }
    final candidates = <(String, FlutterSdkSource)>[
      if (env['FLUTTER_ROOT'] != null) (ctx.join(env['FLUTTER_ROOT']!, 'bin', exe), FlutterSdkSource.flutterRoot),
      if (env['HOME'] != null) (ctx.join(env['HOME']!, 'fvm', 'default', 'bin', exe), FlutterSdkSource.fvm),
      if (env['USERPROFILE'] != null)
        (ctx.join(env['USERPROFILE']!, 'fvm', 'default', 'bin', exe), FlutterSdkSource.fvm),
      for (final dir in (env['PATH'] ?? '').split(windows ? ';' : ':'))
        if (dir.isNotEmpty) (ctx.join(dir, exe), FlutterSdkSource.path),
    ];
    for (final (path, source) in candidates) {
      if (fileExists(path)) return FlutterSdk(path, isWindows: windows, source: source);
    }
    if (!windows) {
      final found = await _fromLoginShell(
        env['SHELL'] ?? '/bin/sh',
        runProcess ?? defaultRunProcess,
        loginShellTimeout,
      );
      if (found != null && fileExists(found)) {
        return FlutterSdk(found, isWindows: false, source: FlutterSdkSource.loginShell);
      }
    }
    throw LaunchException(
      'could not find flutter; choose it in QAFlow Studio settings or pass --flutter '
      '(apps started from the Dock do not inherit the shell PATH)',
    );
  }

  /// The last line `command -v flutter` prints in a login shell, when it is
  /// an absolute path. Anything else (an alias, a function, a timeout, a
  /// shell that fails) means "not found here".
  static Future<String?> _fromLoginShell(String shell, RunProcess run, Duration timeout) async {
    try {
      final result = await run(shell, ['-l', '-c', 'command -v flutter']).timeout(timeout);
      if (result.exitCode != 0) return null;
      final line = LineSplitter.split(
        result.stdout as String,
      ).map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull;
      return line != null && p.posix.isAbsolute(line) ? line : null;
    } on Object {
      return null;
    }
  }

  /// `flutter --version --machine`. Flutter can print notices (an upgrade
  /// banner, analytics) before the JSON, so only the outermost `{...}` is
  /// parsed.
  Future<FlutterVersion> version({RunProcess? runProcess}) async {
    final result = await (runProcess ?? defaultRunProcess)(executable, const [
      '--version',
      '--machine',
    ], runInShell: runInShell);
    final out = result.stdout as String;
    final start = out.indexOf('{');
    final end = out.lastIndexOf('}');
    if (result.exitCode != 0 || start < 0 || end < start) {
      throw LaunchException(
        '`$executable --version --machine` failed (exit ${result.exitCode}): ${(result.stderr as String).trim()}',
      );
    }
    final json = (jsonDecode(out.substring(start, end + 1)) as Map).cast<String, Object?>();
    return FlutterVersion(
      frameworkVersion: json['frameworkVersion'] as String? ?? 'unknown',
      dartSdkVersion: json['dartSdkVersion'] as String? ?? 'unknown',
      channel: json['channel'] as String? ?? 'unknown',
    );
  }
}
