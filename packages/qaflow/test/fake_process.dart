import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FakeProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _stdin = StreamController<List<int>>();
  final _exit = Completer<int>();
  late final IOSink _stdinSink = IOSink(_stdin.sink);
  final List<ProcessSignal> kills = [];

  /// Everything the launcher wrote to stdin, decoded, line by line.
  late final Stream<String> stdinLines = _stdin.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .asBroadcastStream();

  void emit(String line) => _stdout.add(utf8.encode('$line\n'));
  void emitErr(String line) => _stderr.add(utf8.encode('$line\n'));
  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
    _stdout.close();
    _stderr.close();
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _stdinSink;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 4242;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills.add(signal);
    exitWith(-15);
    return true;
  }
}

/// A scripted [ProcessRunner]. Responses are queued per command line
/// (`executable arg1 arg2`); the last queued response repeats, which suits
/// polling. An unscripted command throws, so tests list every command.
class FakeRunner {
  final List<String> calls = [];
  final Map<String, List<ProcessResult>> _responses = {};

  void on(String command, {String stdout = '', String stderr = '', int exitCode = 0}) =>
      _responses.putIfAbsent(command, () => []).add(ProcessResult(0, exitCode, stdout, stderr));

  /// Makes [command] throw like a missing executable.
  void missing(String command) => _responses[command] = const [];

  Future<ProcessResult> call(String executable, List<String> arguments, {Map<String, String>? environment}) async {
    final command = [executable, ...arguments].join(' ');
    calls.add(command);
    final queue = _responses[command];
    if (queue == null) throw StateError('unexpected command: $command');
    if (queue.isEmpty) throw ProcessException(executable, arguments, 'No such file or directory', 2);
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }
}

/// A scripted [ProcessStarter]. A command with no [hang] exits at once with
/// its scripted output; a hanging one stays alive until killed. Started
/// processes are kept per command line so tests can see what was killed.
class FakeStarter {
  final List<String> calls = [];
  final Map<String, FakeProcess> processes = {};
  final Map<String, ({String stdout, String stderr, int exitCode, bool hang})> _scripts = {};

  void on(String command, {String stdout = '', String stderr = '', int exitCode = 0, bool hang = false}) =>
      _scripts[command] = (stdout: stdout, stderr: stderr, exitCode: exitCode, hang: hang);

  Future<Process> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    final command = [executable, ...arguments].join(' ');
    calls.add(command);
    final script = _scripts[command];
    if (script == null) throw StateError('unexpected command: $command');
    final process = FakeProcess();
    processes[command] = process;
    if (!script.hang) {
      if (script.stdout.isNotEmpty) process.emit(script.stdout);
      if (script.stderr.isNotEmpty) process.emitErr(script.stderr);
      process.exitWith(script.exitCode);
    }
    return process;
  }
}

class FakeDetachedStarter {
  final List<String> started = [];
  void Function(String command)? onStart;

  Future<void> call(String executable, List<String> arguments) async {
    final command = [executable, ...arguments].join(' ');
    started.add(command);
    onStart?.call(command);
  }
}
