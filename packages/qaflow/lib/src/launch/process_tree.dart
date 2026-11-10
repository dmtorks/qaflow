import 'dart:async';
import 'dart:io';

import 'process.dart';

/// Sends a signal to a pid; [Process.killPid] in production.
typedef PidSignaller = bool Function(int pid, ProcessSignal signal);

/// Stops a launched process together with everything it started.
///
/// `flutter run` starts the app as its own child, and on macOS that app
/// outlives a kill of `flutter run` alone. Dart starts children in the
/// parent's process group and macOS has no `setsid`, so a group kill is not
/// available; instead the tree is read from `ps` before anything is
/// signalled (an orphan is reparented and can no longer be found from its
/// old parent). Windows kills the tree with `taskkill /T`.
class ProcessTree {
  ProcessTree({
    ProcessRunner runProcess = defaultProcessRunner,
    PidSignaller signalPid = Process.killPid,
    bool? isWindows,
    this.grace = const Duration(seconds: 3),
    this.pollInterval = const Duration(milliseconds: 100),
  }) : _run = runProcess,
       _signal = signalPid,
       _isWindows = isWindows ?? Platform.isWindows;

  /// Kills only the process itself. For processes a test fakes, whose pid
  /// is not theirs to look up or signal.
  const ProcessTree.direct({
    this.grace = const Duration(seconds: 3),
    this.pollInterval = const Duration(milliseconds: 100),
  }) : _run = null,
       _signal = null,
       _isWindows = false;

  final ProcessRunner? _run;
  final PidSignaller? _signal;
  final bool _isWindows;

  /// How long a SIGTERM is given before SIGKILL.
  final Duration grace;
  final Duration pollInterval;

  bool get _walksTree => _run != null && !_isWindows;

  /// Every process below [pid] right now, with its start time; empty where
  /// the tree cannot be read. The start time tells a later look whether a
  /// pid still belongs to the same process.
  Future<Map<int, String>> descendants(int pid) async {
    if (!_walksTree) return {};
    final table = await _table();
    return {for (final child in _below(pid, table)) child: table[child]!.started};
  }

  /// SIGTERM to [root] and its descendants, then SIGKILL to whatever is
  /// still running after [grace]. With [force], SIGKILL at once and no
  /// wait. Completes once that is done.
  Future<void> kill(Process root, {bool force = false}) async {
    var exited = false;
    unawaited(root.exitCode.then((_) => exited = true, onError: (Object _) => exited = true));
    if (_run != null && _isWindows) {
      try {
        final result = await _run('taskkill', ['/PID', '${root.pid}', '/T', '/F']);
        if (result.exitCode == 0) {
          if (!force) await _waitFor(() async => exited);
          return;
        }
      } catch (_) {}
    }
    final below = await descendants(root.pid);
    final first = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
    root.kill(first);
    for (final pid in below.keys) {
      _signal!(pid, first);
    }
    if (force) return;
    if (await _waitFor(() async => exited && (await _alive(below)).isEmpty)) return;
    if (!exited) root.kill(ProcessSignal.sigkill);
    for (final pid in await _alive(below)) {
      _signal!(pid, ProcessSignal.sigkill);
    }
  }

  /// Ends whichever of the [recorded] descendants (from [descendants],
  /// taken before their parent exited) are still running, the same way
  /// [kill] does. A pid whose start time no longer matches has been reused
  /// by another process and is left alone.
  Future<void> killSurvivors(Map<int, String> recorded) async {
    if (!_walksTree || recorded.isEmpty) return;
    final alive = await _alive(recorded);
    if (alive.isEmpty) return;
    for (final pid in alive) {
      _signal!(pid, ProcessSignal.sigterm);
    }
    final remaining = {for (final pid in alive) pid: recorded[pid]!};
    if (await _waitFor(() async => (await _alive(remaining)).isEmpty)) return;
    for (final pid in await _alive(remaining)) {
      _signal!(pid, ProcessSignal.sigkill);
    }
  }

  /// Polls [done] until it holds or [grace] runs out; true if it held.
  Future<bool> _waitFor(Future<bool> Function() done) async {
    final deadline = DateTime.now().add(grace);
    while (true) {
      if (await done()) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// The [recorded] pids still running as the same process (same start time).
  Future<Set<int>> _alive(Map<int, String> recorded) async {
    if (!_walksTree || recorded.isEmpty) return {};
    final table = await _table();
    return {
      for (final MapEntry(key: pid, value: started) in recorded.entries)
        if (table[pid]?.started == started) pid,
    };
  }

  /// Parent pid and start time (`ps` lstart, to the second) of every
  /// process; empty when `ps` fails.
  Future<Map<int, ({int ppid, String started})>> _table() async {
    try {
      final result = await _run!('ps', ['-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'lstart=']);
      if (result.exitCode != 0) return {};
      return {
        for (final line in result.stdout.toString().split('\n'))
          if (line.trim().split(RegExp(r'\s+')) case [
            final pid,
            final ppid,
            ...final started,
          ] when int.tryParse(pid) != null && int.tryParse(ppid) != null && started.isNotEmpty)
            int.parse(pid): (ppid: int.parse(ppid), started: started.join(' ')),
      };
    } catch (_) {
      return {};
    }
  }

  static Set<int> _below(int root, Map<int, ({int ppid, String started})> table) {
    final children = <int, List<int>>{};
    table.forEach((pid, entry) => children.putIfAbsent(entry.ppid, () => []).add(pid));
    final found = <int>{};
    final queue = [root];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <int>[]) {
        if (child != root && found.add(child)) queue.add(child);
      }
    }
    return found;
  }
}

/// The launched processes that are still running, so a qa or studio that is
/// being terminated can kill what a graceful stop could not reach (a launch
/// still in flight, or a stop that ran out of time).
class LiveProcesses {
  final Map<Process, ProcessTree> _live = {};

  int get length => _live.length;

  /// Tracks [process] until it exits.
  void track(Process process, ProcessTree tree) {
    _live[process] = tree;
    unawaited(process.exitCode.then((_) => _live.remove(process), onError: (Object _) => _live.remove(process)));
  }

  /// Kills every tracked process with its tree; with [force], SIGKILL and
  /// no grace period.
  Future<void> killAll({bool force = false}) async {
    await Future.wait([
      for (final MapEntry(key: process, value: tree) in _live.entries.toList())
        tree.kill(process, force: force).catchError((Object _) {}),
    ]);
  }
}

/// The launchers' processes in this isolate.
final liveProcesses = LiveProcesses();
