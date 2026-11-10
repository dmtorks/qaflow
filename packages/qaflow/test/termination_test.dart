import 'dart:async';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  late StreamController<ProcessSignal> signals;
  late List<String> calls;
  late Completer<int> exited;

  setUp(() {
    signals = StreamController<ProcessSignal>();
    calls = [];
    exited = Completer<int>();
  });

  StreamSubscription<ProcessSignal> watch(
    Future<void> Function() shutdown, {
    Duration timeout = const Duration(seconds: 5),
  }) => exitOnTermination(
    shutdown,
    signals: signals.stream,
    timeout: timeout,
    killLeftovers: () async => calls.add('leftovers'),
    forceKillLeftovers: () async => calls.add('force leftovers'),
    exit: (code) {
      calls.add('exit $code');
      if (!exited.isCompleted) exited.complete(code);
    },
  );

  test('SIGTERM runs the shutdown, kills leftovers, then exits with 143', () async {
    watch(() async => calls.add('shutdown'));
    signals.add(ProcessSignal.sigterm);
    expect(await exited.future, 143);
    expect(calls, ['shutdown', 'leftovers', 'exit 143']);
  });

  test('SIGINT exits with 130', () async {
    watch(() async {});
    signals.add(ProcessSignal.sigint);
    expect(await exited.future, 130);
  });

  test('a shutdown that hangs or fails still exits once the timeout is spent', () async {
    watch(() => Completer<void>().future, timeout: const Duration(milliseconds: 20));
    signals.add(ProcessSignal.sigterm);
    expect(await exited.future, 143);
    expect(calls, ['leftovers', 'exit 143']);

    exited = Completer<int>();
    calls.clear();
    signals = StreamController<ProcessSignal>();
    watch(() async => throw StateError('boom'));
    signals.add(ProcessSignal.sigint);
    expect(await exited.future, 130);
  });

  test('a second signal exits without waiting for the shutdown', () async {
    final shutdown = Completer<void>();
    watch(() => shutdown.future);
    signals.add(ProcessSignal.sigint);
    await Future<void>.delayed(Duration.zero);
    signals.add(ProcessSignal.sigint);
    expect(await exited.future, 130);
    expect(calls, ['force leftovers', 'exit 130']);
    expect(shutdown.isCompleted, isFalse);
  });

  test('terminationSignals can be listened to and cancelled', () async {
    final subscription = terminationSignals().listen((_) {});
    await subscription.cancel();
  });
}
