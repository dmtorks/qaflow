import 'dart:async';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'fake_process.dart';

void main() {
  test('runUntil returns the output and exit code of a process that finishes', () async {
    final starter = FakeStarter()..on('tool go', stdout: 'out', stderr: 'err', exitCode: 3);
    final r = await runUntil(starter.call, 'tool', ['go'], stop: Completer<void>().future);
    expect(r.exitCode, 3);
    expect(r.stdout.toString().trim(), 'out');
    expect(r.stderr.toString().trim(), 'err');
    expect(starter.processes['tool go']!.kills, isEmpty);
  });

  test('runUntil kills the process when stop completes first and returns its exit code', () async {
    final starter = FakeStarter()..on('tool wait', hang: true);
    final stop = Completer<void>();
    final result = runUntil(starter.call, 'tool', ['wait'], stop: stop.future);
    await pumpEventQueue();
    expect(starter.processes['tool wait']!.kills, isEmpty);
    stop.complete();
    expect((await result).exitCode, -15);
    expect(starter.processes['tool wait']!.kills, [ProcessSignal.sigterm]);
  });

  test('runUntil does not kill a process that already finished', () async {
    final starter = FakeStarter()..on('tool go');
    final stop = Completer<void>();
    await runUntil(starter.call, 'tool', ['go'], stop: stop.future);
    stop.complete();
    await pumpEventQueue();
    expect(starter.processes['tool go']!.kills, isEmpty);
  });
}
