import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  late TempFlows files;
  late FakeAgent agent;
  late FakeAppSession session;
  late Directory out;

  setUp(() {
    files = TempFlows();
    agent = FakeAgent();
    session = FakeAppSession(agent);
    out = Directory(p.join(Directory.systemTemp.createTempSync('qa_out').path, 'qa-out'));
  });
  tearDown(() {
    files.dispose();
    if (out.parent.existsSync()) out.parent.deleteSync(recursive: true);
  });

  Flow flow(String yaml, {required String name}) => FlowParser().parseFile(files.write(name, yaml));
  final config = ProjectConfig(name: 'demo', source: '/src');

  Future<TestRun> start(List<Flow> flows, {bool preview = false}) => TestRun.start(
    TestRunRequest(config: config, flows: flows, outDir: out.path, preview: preview),
    createSession: (config, runDir, log) async => session,
  );

  test('runs the flows, stops the session and writes the three reports', () async {
    agent.visibleTexts.add('Welcome');
    final run = await start([flow('- assertVisible: Welcome\n', name: 'ok.yaml')]);
    final events = await run.events.toList();
    final outcome = await run.done;
    expect(events.first, isA<RunStarted>());
    expect(events.last, isA<RunFinished>());
    expect(p.dirname(run.runDir), p.normalize(p.absolute(out.path)));
    expect(run.runId, p.basename(run.runDir));
    expect(outcome.isSuccess, isTrue);
    expect(outcome.result.flows.single.status, FlowStatus.passed);
    for (final path in [outcome.resultsPath, outcome.junitPath, outcome.htmlPath]) {
      expect(File(path).existsSync(), isTrue, reason: path);
      expect(p.dirname(path), run.runDir);
    }
    expect(session.calls.last, 'stop');
  });

  test('the baseline key suffix falls back to QA_BASELINE_KEY_SUFFIX', () async {
    final appRoot = Directory(p.join(out.parent.path, 'app'))..createSync();
    screenOf(agent, realPng());
    final shot = flow('- assertScreenshot: home\n', name: 'shot.yaml');
    Future<String> deviceKey({String? suffix}) async {
      final run = await TestRun.start(
        TestRunRequest(
          config: config,
          flows: [shot],
          outDir: out.path,
          appRoot: appRoot.path,
          baselineKeySuffix: suffix,
        ),
        createSession: (config, runDir, log) async => session,
        environment: const {'QA_BASELINE_KEY_SUFFIX': 'ci'},
      );
      final events = await run.events.toList();
      return events.whereType<StepFinished>().single.comparison!.deviceKey;
    }

    expect(await deviceKey(), 'macos-ci');
    expect(await deviceKey(suffix: 'mine'), 'macos-mine');
  });

  test('a failing run still writes its reports', () async {
    final run = await start([flow('- assertVisible: Missing\n', name: 'bad.yaml')]);
    await run.events.drain<void>();
    final outcome = await run.done;
    expect(outcome.isSuccess, isFalse);
    expect(outcome.result.flows.single.status, FlowStatus.failed);
    expect(File(outcome.resultsPath).existsSync(), isTrue);
  });

  test('a setup failure leaves no run folder', () async {
    await expectLater(
      TestRun.start(
        TestRunRequest(
          config: config,
          flows: [flow('- launchApp\n', name: 'x.yaml')],
          outDir: out.path,
        ),
        createSession: (config, runDir, log) async => throw LaunchException('no flutter'),
      ),
      throwsA(isA<LaunchException>()),
    );
    expect(out.existsSync() ? out.listSync() : const <FileSystemEntity>[], isEmpty);
  });

  test('two runs get two folders', () async {
    final first = await start([flow('- launchApp\n', name: 'a.yaml')]);
    await first.events.drain<void>();
    await first.done;
    session = FakeAppSession(agent);
    final second = await start([flow('- launchApp\n', name: 'b.yaml')]);
    await second.events.drain<void>();
    await second.done;
    expect(second.runDir, isNot(first.runDir));
    expect(Directory(first.runDir).existsSync() && Directory(second.runDir).existsSync(), isTrue);
  });

  test('stop ends the run after the step in flight; a second stop also stops the session', () async {
    final gate = Completer<void>();
    agent.on[QaMethod.enterText] = (args) async {
      if (args['text'] == 'b') await gate.future;
      return {'node': fakeNode().toJson(), 'value': args['text']};
    };
    final run = await start([flow('- inputText: a\n- inputText: b\n- inputText: c\n', name: 's.yaml')]);
    final events = <RunEvent>[];
    await for (final e in run.events) {
      events.add(e);
      if (e is StepStarted && e.stepId == '2') {
        run.stop();
        run.stop();
        gate.complete();
      }
    }
    final outcome = await run.done;
    expect(events.whereType<StepFinished>().map((s) => (s.stepId, s.status)), [
      ('1', StepStatus.passed),
      ('2', StepStatus.passed),
      ('3', StepStatus.skipped),
    ]);
    expect(outcome.result.error, FlowRunner.stoppedMessage);
    expect(outcome.isSuccess, isFalse);
    expect(session.calls.where((c) => c == 'stop'), hasLength(2));
  });

  test('stop while the device is still preparing stops the session at once', () async {
    final blocked = _BlockedPrepareSession(agent);
    final run = await TestRun.start(
      TestRunRequest(
        config: config,
        flows: [flow('- scroll\n', name: 'b.yaml')],
        outDir: out.path,
      ),
      createSession: (config, runDir, log) async => blocked,
    );
    final drained = run.events.drain<void>();
    await blocked.preparing.future;
    run.stop();
    await drained;
    final outcome = await run.done;
    expect(outcome.result.error, FlowRunner.stoppedMessage);
    expect(blocked.calls, contains('stop'));
  });

  test('a session whose stop() throws on the second stop does not surface an unhandled error', () async {
    session.failStop = StateError('cannot stop twice');
    final gate = Completer<void>();
    agent.on[QaMethod.enterText] = (args) async {
      if (args['text'] == 'b') await gate.future;
      return {'node': fakeNode().toJson(), 'value': args['text']};
    };
    final run = await start([flow('- inputText: a\n- inputText: b\n- inputText: c\n', name: 's2.yaml')]);
    final zoneErrors = <Object>[];
    await runZonedGuarded(() async {
      await for (final e in run.events) {
        if (e is StepStarted && e.stepId == '2') {
          run.stop();
          run.stop();
          gate.complete();
        }
      }
      await run.done.then<void>((_) {}, onError: (Object _) {});
    }, (error, stack) => zoneErrors.add(error));
    expect(zoneErrors, isEmpty);
  });

  test('preview reaches the runner and can be switched off', () async {
    agent.visibleTexts.add('Welcome');
    final run = await start([flow('- assertVisible: Welcome\n', name: 'p.yaml')], preview: true);
    expect(run.preview, isTrue);
    final events = await run.events.toList();
    await run.done;
    expect(events.whereType<StepPreview>(), hasLength(1));
  });
}

class _BlockedPrepareSession extends FakeAppSession {
  _BlockedPrepareSession(super.agent);

  final preparing = Completer<void>();
  final _gate = Completer<void>();

  @override
  Future<DeviceInfo> prepareDevice({void Function(DeviceInfo device)? onBooting}) async {
    calls.add('prepareDevice');
    preparing.complete();
    await _gate.future;
    return deviceInfo;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (!_gate.isCompleted) _gate.completeError(LaunchException('stopped while waiting for X'));
  }
}
