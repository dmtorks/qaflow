import 'dart:async';
import 'dart:io' as io;
import 'dart:io' show ProcessSignal;

import 'process_tree.dart';

/// SIGINT and SIGTERM as one stream. Windows has no SIGTERM to watch.
Stream<ProcessSignal> terminationSignals({bool? isWindows}) {
  final windows = isWindows ?? io.Platform.isWindows;
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  late final StreamController<ProcessSignal> controller;
  controller = StreamController<ProcessSignal>(
    onListen: () {
      subscriptions.add(ProcessSignal.sigint.watch().listen(controller.add));
      if (!windows) subscriptions.add(ProcessSignal.sigterm.watch().listen(controller.add));
    },
    onCancel: () => Future.wait([for (final s in subscriptions) s.cancel()]),
  );
  return controller.stream;
}

/// Makes SIGINT and SIGTERM end this process the way a normal quit does.
///
/// The first signal runs [shutdown] (bounded by [timeout]), then
/// [killLeftovers] (by default every launched process still running, with
/// its tree, SIGTERM then SIGKILL), then exits with 128 + the signal number.
/// A second signal does not wait for any of that: it runs
/// [forceKillLeftovers] (by default SIGKILL to those trees, no grace
/// period, bounded by two seconds) and exits at once. Cancel the
/// subscription to stop handling signals.
StreamSubscription<ProcessSignal> exitOnTermination(
  Future<void> Function() shutdown, {
  Stream<ProcessSignal>? signals,
  Duration timeout = const Duration(seconds: 15),
  Future<void> Function()? killLeftovers,
  Future<void> Function()? forceKillLeftovers,
  void Function(int code) exit = io.exit,
}) {
  final leftovers = killLeftovers ?? liveProcesses.killAll;
  final forceLeftovers = forceKillLeftovers ?? () => liveProcesses.killAll(force: true);
  var exiting = false;

  Future<void> run(Future<void> Function() step, Duration bound) async {
    try {
      await step().timeout(bound);
    } catch (_) {
      // Exiting regardless; what this step could not stop is left to the next.
    }
  }

  return (signals ?? terminationSignals()).listen((signal) async {
    final code = 128 + signal.signalNumber;
    if (exiting) {
      await run(forceLeftovers, const Duration(seconds: 2));
      exit(code);
      return;
    }
    exiting = true;
    await run(shutdown, timeout);
    await run(leftovers, timeout);
    exit(code);
  });
}
