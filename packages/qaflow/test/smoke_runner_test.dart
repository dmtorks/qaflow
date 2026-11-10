import 'dart:convert';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

/// Answers every call with a settled idle and, for screenshot, inline base64
/// PNG bytes -- matching QaDriver.screenshot's default `inline` transfer,
/// which asks the agent for pixel data and writes the file itself rather
/// than asking the agent to write it (the agent may be sandboxed).
class NullTransport implements QaTransport {
  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) async {
    if (method == QaMethod.screenshot) {
      return QaResponse.success({
        'format': 'png',
        'data': base64Encode([1, 2, 3]),
        'width': 1,
        'height': 1,
        'devicePixelRatio': 1.0,
      });
    }
    return QaResponse.success({'settled': 'idle'});
  }
}

void main() {
  test('runs steps in order, stops at the first failure, screenshots it', () async {
    final dir = Directory.systemTemp.createTempSync('smoke');
    addTearDown(() => dir.deleteSync(recursive: true));
    final order = <String>[];
    final runner = SmokeRunner(QaDriver(NullTransport()), outDir: dir.path);
    final report = await runner.run([
      SmokeStep('one', (_) async => order.add('one')),
      SmokeStep('two', (_) async => throw StateError('boom')),
      SmokeStep('three', (_) async => order.add('three')),
    ]);
    expect(order, ['one']);
    expect(report.passed, isFalse);
    expect(report.results.map((r) => r.ok), [true, false]);
    expect(report.results[1].error, contains('boom'));
    expect(File('${dir.path}/failure-two.png').existsSync(), isTrue);
    expect(report.toText(), contains('FAIL'));
    expect(File('${dir.path}/smoke.log').existsSync(), isTrue);
  });

  test('all passing steps produce a passing report', () async {
    final dir = Directory.systemTemp.createTempSync('smoke');
    addTearDown(() => dir.deleteSync(recursive: true));
    final report = await SmokeRunner(
      QaDriver(NullTransport()),
      outDir: dir.path,
    ).run([SmokeStep('a', (_) async {}), SmokeStep('b', (_) async {})]);
    expect(report.passed, isTrue);
    expect(report.toText().split('\n').where((l) => l.startsWith('PASS')).length, 2);
  });

  test('demo steps are the documented scenario', () {
    final names = demoAppSmokeSteps('/out').map((s) => s.name).toList();
    expect(names.first, 'wait for idle');
    expect(names, contains('scroll list'));
    expect(names.last, 'final screenshot');
    expect(names.length, 22);
  });
}
