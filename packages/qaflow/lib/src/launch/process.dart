import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool runInShell,
    });

Future<Process> defaultProcessStarter(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool runInShell = false,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  runInShell: runInShell,
);

/// Runs a short command to completion. Injected so tests never run real tools.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments, {Map<String, String>? environment});

Future<ProcessResult> defaultProcessRunner(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.run(executable, arguments, environment: environment);

/// Starts a process that outlives this one (an Android emulator).
typedef DetachedStarter = Future<void> Function(String executable, List<String> arguments);

Future<void> defaultDetachedStarter(String executable, List<String> arguments) =>
    Process.start(executable, arguments, mode: ProcessStartMode.detached);

/// Runs a command to completion like [ProcessRunner], but kills it (SIGTERM)
/// if [stop] completes first, so an abandoned wait leaves nothing running.
/// A killed process still returns its exit code.
Future<ProcessResult> runUntil(
  ProcessStarter start,
  String executable,
  List<String> arguments, {
  required Future<void> stop,
}) async {
  final process = await start(executable, arguments);
  final stdout = utf8.decodeStream(process.stdout);
  final stderr = utf8.decodeStream(process.stderr);
  var exited = false;
  unawaited(
    stop.then((_) {
      if (!exited) process.kill();
    }, onError: (Object _) {}),
  );
  final exitCode = await process.exitCode;
  exited = true;
  return ProcessResult(process.pid, exitCode, await stdout, await stderr);
}
