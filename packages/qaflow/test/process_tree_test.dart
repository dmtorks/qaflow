import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'fake_process.dart';

/// A process table that `ps` reads and signals change: a signalled pid
/// dies unless it is [stubborn] to that signal, and its children are
/// reparented to 1 as the kernel would.
class FakeTable {
  FakeTable(this.parents);

  /// The start time every process has unless [starts] gives another.
  static const started = 'Sat Oct 10 08:00:00 2026';

  final Map<int, int> parents;
  final Map<int, String> starts = {};
  final Set<int> stubborn = {};
  final List<(int, ProcessSignal)> signals = [];
  final List<String> commands = [];

  Future<ProcessResult> run(String executable, List<String> arguments, {Map<String, String>? environment}) async {
    commands.add([executable, ...arguments].join(' '));
    final out = [for (final e in parents.entries) '  ${e.key} ${e.value} ${starts[e.key] ?? started}'].join('\n');
    return ProcessResult(0, 0, '$out\n', '');
  }

  bool signal(int pid, ProcessSignal signal) {
    signals.add((pid, signal));
    if (!parents.containsKey(pid)) return false;
    if (signal == ProcessSignal.sigterm && stubborn.contains(pid)) return true;
    die(pid);
    return true;
  }

  void die(int pid) {
    parents.remove(pid);
    for (final child in [...parents.keys]) {
      if (parents[child] == pid) parents[child] = 1;
    }
  }

  ProcessTree tree({bool isWindows = false}) => ProcessTree(
    runProcess: run,
    signalPid: signal,
    isWindows: isWindows,
    grace: const Duration(milliseconds: 50),
    pollInterval: const Duration(milliseconds: 5),
  );
}

/// [FakeProcess] (pid 4242) that leaves [table] when it is killed.
FakeProcess rootIn(FakeTable table) {
  final process = _TrackedProcess(table);
  table.parents[process.pid] = 1;
  return process;
}

class _TrackedProcess extends FakeProcess {
  _TrackedProcess(this.table);
  final FakeTable table;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    table.die(this.pid); // a bare `pid` is dart:io's own pid
    return super.kill(signal);
  }
}

void main() {
  test('descendants walks the whole tree below a pid and nothing else', () async {
    final table = FakeTable({100: 1, 200: 100, 300: 200, 301: 200, 400: 1, 500: 400});
    table.starts[300] = 'Sat Oct 10 09:30:00 2026';
    expect(await table.tree().descendants(100), {
      200: FakeTable.started,
      300: 'Sat Oct 10 09:30:00 2026',
      301: FakeTable.started,
    });
    expect(table.commands, ['ps -A -o pid= -o ppid= -o lstart=']);
  });

  test('kill terminates the root and every descendant, leaving other processes alone', () async {
    final table = FakeTable({5000: 4242, 5001: 5000, 6000: 1});
    final root = rootIn(table);
    await table.tree().kill(root);
    expect(root.kills, [ProcessSignal.sigterm]);
    expect(table.signals, [(5000, ProcessSignal.sigterm), (5001, ProcessSignal.sigterm)]);
    expect(table.parents.keys, [6000]);
  });

  test('kill escalates to SIGKILL for a descendant that ignores SIGTERM', () async {
    final table = FakeTable({5000: 4242, 5001: 5000});
    table.stubborn.add(5001);
    final root = rootIn(table);
    await table.tree().kill(root);
    expect(table.signals, contains((5001, ProcessSignal.sigkill)));
    expect(table.parents, isEmpty);
  });

  test('kill uses taskkill /T on Windows', () async {
    final root = FakeProcess();
    final calls = <String>[];
    final tree = ProcessTree(
      runProcess: (exe, args, {environment}) async {
        calls.add([exe, ...args].join(' '));
        root.exitWith(1);
        return ProcessResult(0, 0, '', '');
      },
      signalPid: (pid, signal) => fail('no signals on Windows'),
      isWindows: true,
      grace: const Duration(milliseconds: 50),
    );
    await tree.kill(root);
    expect(calls, ['taskkill /PID 4242 /T /F']);
    expect(root.kills, isEmpty);
  });

  test('killSurvivors ends recorded orphans but not a reused pid', () async {
    // 7000 was the app and is now an orphan under launchd. 7001 has exited
    // and its pid now belongs to another launchd child that started later.
    // 7002 has exited and nothing reuses it.
    final table = FakeTable({7000: 1, 7001: 1});
    table.starts[7001] = 'Sat Oct 10 08:00:31 2026';
    await table.tree().killSurvivors({7000: FakeTable.started, 7001: FakeTable.started, 7002: FakeTable.started});
    expect(table.signals, [(7000, ProcessSignal.sigterm)]);
    expect(table.parents.keys, [7001]);
  });

  test('a forced kill sends SIGKILL to the tree at once', () async {
    final table = FakeTable({5000: 4242, 5001: 5000});
    table.stubborn.add(5001);
    final root = rootIn(table);
    await table.tree().kill(root, force: true);
    expect(root.kills, [ProcessSignal.sigkill]);
    expect(table.signals, [(5000, ProcessSignal.sigkill), (5001, ProcessSignal.sigkill)]);
    expect(table.parents, isEmpty);
  });

  test('the direct tree only kills the process itself', () async {
    final root = FakeProcess();
    const tree = ProcessTree.direct(grace: Duration(milliseconds: 50));
    expect(await tree.descendants(root.pid), isEmpty);
    await tree.kill(root);
    expect(root.kills, [ProcessSignal.sigterm]);
  });

  test('LiveProcesses kills what is still running and forgets what exited', () async {
    final live = LiveProcesses();
    final running = FakeProcess();
    final exited = FakeProcess();
    live
      ..track(running, const ProcessTree.direct())
      ..track(exited, const ProcessTree.direct());
    exited.exitWith(0);
    await Future<void>.delayed(Duration.zero);
    expect(live.length, 1);
    await live.killAll();
    expect(running.kills, [ProcessSignal.sigterm]);
    expect(exited.kills, isEmpty);
  });

  group('FlutterRunLauncher', () {
    late FakeTable table;
    late FakeProcess flutterRun;

    Future<LaunchedApp> launch(Duration stopTimeout) {
      final future = FlutterRunLauncher(
        config: ProjectConfig(name: 'demo', source: '/p/demo', device: 'macos'),
        sdk: FlutterSdk('/sdk/bin/flutter', isWindows: false),
        processStarter: (exe, args, {workingDirectory, environment, runInShell = false}) async => flutterRun,
        processTree: table.tree(),
        stopTimeout: stopTimeout,
      ).start();
      flutterRun
        ..emit('[{"event":"app.start","params":{"appId":"a1","mode":"debug","supportsRestart":true}}]')
        ..emit('[{"event":"app.debugPort","params":{"appId":"a1","port":5,"wsUri":"ws://127.0.0.1:5/ws"}}]')
        ..emit('[{"event":"app.started","params":{"appId":"a1"}}]');
      return future;
    }

    setUp(() {
      table = FakeTable({7000: 4242, 6000: 1});
      flutterRun = rootIn(table);
    });

    test('stop kills the app when flutter run exits without stopping it', () async {
      final app = await launch(const Duration(seconds: 5));
      final stopping = app.stop();
      await flutterRun.stdinLines.first;
      flutterRun.emit('[{"id":1,"result":true}]');
      table.die(flutterRun.pid);
      flutterRun.exitWith(0);
      await stopping;
      expect(flutterRun.kills, isEmpty);
      expect(table.signals, [(7000, ProcessSignal.sigterm)]);
      expect(table.parents.keys, [6000]);
    });

    test('a stop that times out kills flutter run and the app', () async {
      final app = await launch(const Duration(milliseconds: 20));
      await app.stop();
      expect(flutterRun.kills, [ProcessSignal.sigterm]);
      expect(table.signals, [(7000, ProcessSignal.sigterm)]);
      expect(table.parents.keys, [6000]);
    });
  });

  group('real processes', () {
    // A shell that starts a sleeping grandchild and prints its pid, like
    // flutter run starting the app.
    Future<(Process, int)> startTree() async {
      final process = await Process.start('/bin/sh', ['-c', r'sleep 300 & echo $!; wait']);
      final line = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      return (process, int.parse(line.trim()));
    }

    Future<bool> isRunning(int pid) async => (await Process.run('ps', ['-p', '$pid'])).exitCode == 0;

    Future<String> startOf(int pid) async =>
        (await Process.run('ps', ['-o', 'lstart=', '-p', '$pid'])).stdout.toString().trim();

    /// SIGKILLs [pid] at teardown, but only while it is still the sleep this
    /// test started (same start time), never a process that reused the pid.
    Future<void> killAtTeardown(int pid) async {
      final started = await startOf(pid);
      addTearDown(() async {
        if (started.isNotEmpty && await startOf(pid) == started) Process.killPid(pid, ProcessSignal.sigkill);
      });
    }

    test('a plain kill orphans the grandchild; ProcessTree.kill does not', () async {
      final (plain, orphan) = await startTree();
      await killAtTeardown(orphan);
      plain.kill();
      await plain.exitCode;
      expect(await isRunning(orphan), isTrue, reason: 'the problem this guards against');

      final (process, grandchild) = await startTree();
      await killAtTeardown(grandchild);
      await ProcessTree().kill(process);
      await process.exitCode;
      expect(await isRunning(grandchild), isFalse);
    });

    test('killSurvivors ends a grandchild orphaned before the stop', () async {
      final (process, grandchild) = await startTree();
      await killAtTeardown(grandchild);
      final tree = ProcessTree();
      final below = await tree.descendants(process.pid);
      expect(below, contains(grandchild));
      process.kill();
      await process.exitCode;
      await tree.killSurvivors(below);
      expect(await isRunning(grandchild), isFalse);
    });
  }, skip: Platform.isWindows ? 'POSIX process trees' : false);
}
