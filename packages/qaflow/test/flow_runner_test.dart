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
  late Directory runDir;
  late Directory appRoot;

  setUp(() {
    appRoot = Directory.systemTemp.createTempSync('qa_app');
    files = TempFlows();
    agent = FakeAgent();
    session = FakeAppSession(agent);
    runDir = Directory.systemTemp.createTempSync('qa_run');
  });
  tearDown(() {
    files.dispose();
    runDir.deleteSync(recursive: true);
    appRoot.deleteSync(recursive: true);
  });

  Flow flow(String yaml, {required String name}) => FlowParser().parseFile(files.write(name, yaml));

  Future<List<RunEvent>> run(
    List<Flow> flows, {
    Map<String, String> env = const {},
    int retries = 0,
    ScreenshotPolicy screenshots = ScreenshotPolicy.failures,
    String? appRoot,
    BaselineMode baselines = BaselineMode.record,
    String? baselineKeySuffix,
  }) => FlowRunner(
    session: session,
    flows: flows,
    options: FlowRunOptions(
      runDir: runDir.path,
      runId: 'r1',
      project: 'demo',
      mode: 'debug',
      env: env,
      retries: retries,
      screenshots: screenshots,
      appRoot: appRoot,
      baselines: baselines,
      baselineKeySuffix: baselineKeySuffix,
    ),
  ).run().toList();

  List<StepFinished> steps(List<RunEvent> events) => events.whereType<StepFinished>().toList();
  FlowFinished finished(List<RunEvent> events, String name) =>
      events.whereType<FlowFinished>().singleWhere((e) => e.flow.name == name);

  test('assertScreenshot: recorded is warned with a note and a comparison', () async {
    screenOf(agent, realPng());
    final events = await run([flow('- assertScreenshot: home\n', name: 'shot.yaml')], appRoot: appRoot.path);
    final step = steps(events).single;
    expect(step.status, StepStatus.warned);
    expect(step.note, 'baseline recorded');
    expect(step.comparison!.outcome, ComparisonOutcome.recorded);
    expect(step.comparison!.actual, 'flows/shot/screenshots/home.actual.png');
    expect(File(p.join(appRoot.path, '.qa', 'baselines', 'macos', 'shot', 'home.png')).existsSync(), isTrue);
  });

  test('assertScreenshot: a mismatch fails with screenshot_mismatch and no extra failure screenshot', () async {
    final f = flow('- assertScreenshot: home\n', name: 'shot.yaml');
    screenOf(agent, realPng());
    await run([f], appRoot: appRoot.path);
    screenOf(agent, realPng(black: (0, 0)));
    final events = await run([f], appRoot: appRoot.path);
    final step = steps(events).single;
    expect(step.status, StepStatus.failed);
    expect(step.error!.code, 'screenshot_mismatch');
    expect(step.error!.message, '6.25% of pixels differ (threshold 0.1%)');
    expect(step.artifacts.where((a) => a.contains('failure-')), isEmpty);
    expect(step.comparison!.diff, 'flows/shot/screenshots/home.diff.png');
  });

  test('an optional assertScreenshot that mismatches is warned', () async {
    final f = flow('- assertScreenshot:\n    name: home\n    optional: true\n', name: 'shot.yaml');
    screenOf(agent, realPng());
    await run([f], appRoot: appRoot.path);
    screenOf(agent, realPng(black: (0, 0)));
    final step = steps(await run([f], appRoot: appRoot.path)).single;
    expect(step.status, StepStatus.warned);
    expect(step.error!.code, 'screenshot_mismatch');
    expect(step.comparison!.outcome, ComparisonOutcome.failed);
  });

  test('screenshots: all adds no step screenshot to an assertScreenshot step', () async {
    screenOf(agent, realPng());
    final events = await run(
      [flow('- assertScreenshot: home\n', name: 'shot.yaml')],
      appRoot: appRoot.path,
      screenshots: ScreenshotPolicy.all,
    );
    expect(steps(events).single.artifacts, ['flows/shot/screenshots/home.actual.png']);
  });

  test('the baseline key suffix and the top-level flow slug are used inside a subflow', () async {
    files.write('sub.yaml', '- assertScreenshot: home\n');
    screenOf(agent, realPng());
    await run(
      [flow('- runFlow: sub.yaml\n', name: 'main.yaml')],
      appRoot: appRoot.path,
      baselineKeySuffix: 'ci',
    );
    expect(File(p.join(appRoot.path, '.qa', 'baselines', 'macos-ci', 'main', 'home.png')).existsSync(), isTrue);
  });

  test('a retried flow keeps each attempt\'s screenshots apart', () async {
    final f = flow('- assertScreenshot: home\n', name: 'shot.yaml');
    screenOf(agent, realPng());
    await run([f], appRoot: appRoot.path);
    screenOf(agent, realPng(black: (0, 0)));
    session.onReset = () => screenOf(agent, realPng());
    final events = await run([f], appRoot: appRoot.path, retries: 1);
    expect(finished(events, 'shot').status, FlowStatus.flaky);
    final comparisons = steps(events).map((s) => s.comparison!).toList();
    expect(comparisons.map((c) => c.outcome), [ComparisonOutcome.failed, ComparisonOutcome.passed]);
    expect(comparisons.map((c) => c.actual), [
      'flows/shot/screenshots/home.actual.png',
      'flows/shot/screenshots/attempt-2/home.actual.png',
    ]);
    expect(comparisons.first.diff, 'flows/shot/screenshots/home.diff.png');
    for (final c in comparisons) {
      expect(File(p.join(runDir.path, c.actual)).existsSync(), isTrue);
    }
  });

  group('baseline slug', () {
    Flow qaFlow(String relative, String yaml) {
      final file = File(p.join(appRoot.path, '.qa', relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(yaml);
      return FlowParser().parseFile(p.normalize(file.path));
    }

    bool baseline(String slug) =>
        File(p.join(appRoot.path, '.qa', 'baselines', 'macos', slug, 'home.png')).existsSync();

    test('is the flow file path under .qa, not the flow name', () async {
      screenOf(agent, realPng());
      await run([
        qaFlow('flows/a/same.yaml', 'name: Same\n---\n- assertScreenshot: home\n'),
        qaFlow('flows/b/same.yaml', 'name: Same\n---\n- assertScreenshot: home\n'),
      ], appRoot: appRoot.path);
      expect(baseline('flows-a-same'), isTrue);
      expect(baseline('flows-b-same'), isTrue);
    });

    test('does not depend on the other flows in the run', () async {
      screenOf(agent, realPng());
      final other = qaFlow('flows/other.yaml', 'name: Shot\n---\n- assertVisible: Ready\n');
      final shot = qaFlow('flows/shot.yaml', 'name: Shot\n---\n- assertScreenshot: home\n');
      agent.visibleTexts.add('Ready');
      final events = await run([other, shot], appRoot: appRoot.path);
      expect(steps(events).last.comparison!.baselinePath, '.qa/baselines/macos/flows-shot/home.png');
      final alone = await run([shot], appRoot: appRoot.path);
      expect(steps(alone).single.comparison!.baselinePath, '.qa/baselines/macos/flows-shot/home.png');
    });

    test('a subflow uses the top-level flow file', () async {
      qaFlow('flows/mobile/parts/sub.yaml', '- assertScreenshot: home\n');
      screenOf(agent, realPng());
      await run([qaFlow('flows/mobile/back.yaml', '- runFlow: parts/sub.yaml\n')], appRoot: appRoot.path);
      expect(baseline('flows-mobile-back'), isTrue);
      expect(baseline('flows-mobile-parts-sub'), isFalse);
    });

    test('maps file paths to slugs', () {
      expect(FlowRunner.baselineSlug('/app/.qa/flows/screenshot.yaml', '/app'), 'flows-screenshot');
      expect(FlowRunner.baselineSlug('/app/.qa/flows/mobile/back.yaml', '/app'), 'flows-mobile-back');
      expect(FlowRunner.baselineSlug('/elsewhere/My Flow.yaml', '/app'), 'my-flow');
      expect(FlowRunner.baselineSlug('/app/.qa/flows/x.yaml', null), 'x');
    });
  });

  test('the device is prepared before the first start and reported', () async {
    session.boots = const DeviceInfo(
      platform: DevicePlatform.ios,
      name: 'iPhone 17 Pro',
      id: 'U1',
      osVersion: 'iOS 26.5',
    );
    session.deviceInfo = session.boots!;
    final events = await run([flow('- scroll\n', name: 'a.yaml')]);
    expect(session.calls.take(2), ['prepareDevice', 'start']);
    expect(events[1], isA<DeviceBooting>().having((e) => e.device.id, 'id', 'U1'));
    expect(events[2], isA<DeviceReady>().having((e) => e.device.title, 'title', 'iPhone 17 Pro (iOS 26.5)'));
  });

  test('no DeviceBooting when the device was already up', () async {
    final events = await run([flow('- scroll\n', name: 'a.yaml')]);
    expect(events.whereType<DeviceBooting>(), isEmpty);
    expect(events.whereType<DeviceReady>().single.device.title, 'macOS');
  });

  test('a device that cannot be prepared ends the run with every flow not run', () async {
    session.failPrepare = LaunchException('no iOS simulator named "x"');
    final events = await run([flow('- scroll\n', name: 'a.yaml')]);
    expect(finished(events, 'a').status, FlowStatus.notRun);
    expect((events.last as RunFinished).error, 'no iOS simulator named "x"');
  });

  test('portrait is restored after a flow that rotated, even when it failed', () async {
    final device = RecordingController();
    session.controller = device;
    final events = await run([
      flow('- setOrientation: LANDSCAPE\n- assertVisible: Nope\n', name: 'rotate.yaml'),
      flow('- scroll\n', name: 'next.yaml'),
    ]);
    expect(finished(events, 'rotate').status, FlowStatus.failed);
    expect(device.calls, ['orientation landscapeLeft', 'orientation portrait']);
  });

  test('portrait is restored when the setOrientation step itself fails after rotating', () async {
    final device = RecordingController();
    session.controller = device;
    var rotated = false;
    device.onCall = () => rotated = !rotated;
    agent.on[QaMethod.waitForIdle] = (_) {
      if (rotated) throw QaException(QaErrorCode.internal, 'never settled');
      return {'settled': 'idle'};
    };
    final events = await run([flow('- setOrientation: LANDSCAPE\n', name: 'rotate.yaml')]);
    expect(finished(events, 'rotate').status, FlowStatus.failed);
    expect(device.calls, ['orientation landscapeLeft', 'orientation portrait']);
  });

  test('a failed restore is logged and does not change the status', () async {
    final device = RecordingController();
    session.controller = device;
    var n = 0;
    device.onCall = () {
      if (++n == 2) throw QaException(QaErrorCode.internal, 'adb gone');
    };
    final events = await run([flow('- setOrientation: LANDSCAPE\n', name: 'rotate.yaml')]);
    expect(finished(events, 'rotate').status, FlowStatus.passed);
    expect(
      events.whereType<AppLog>().map((e) => e.line),
      contains('[qa] could not restore portrait orientation: adb gone'),
    );
  });

  test('a flow that rotates then stops the app resets the device orientation', () async {
    final device = RecordingController();
    session.controller = device;
    await run([flow('- setOrientation: LANDSCAPE\n- stopApp\n', name: 'rotate.yaml')]);
    expect(device.calls, ['orientation landscapeLeft', 'reset orientation']);
  });

  test('a failed reset without the app is logged', () async {
    final device = RecordingController();
    session.controller = device;
    var n = 0;
    device.onCall = () {
      if (++n == 2) throw QaException(QaErrorCode.internal, 'adb gone');
    };
    final events = await run([flow('- setOrientation: LANDSCAPE\n- stopApp\n', name: 'rotate.yaml')]);
    expect(finished(events, 'rotate').status, FlowStatus.passed);
    expect(
      events.whereType<AppLog>().map((e) => e.line),
      contains('[qa] could not restore portrait orientation: adb gone'),
    );
  });

  test('flows that never rotate do not touch the device', () async {
    final device = RecordingController();
    session.controller = device;
    await run([flow('- scroll\n', name: 'a.yaml')]);
    expect(device.calls, isEmpty);
  });

  List<Object?> typed() => [for (final a in agent.argsFor(QaMethod.enterText)) a['text']];

  test('a passing flow', () async {
    agent.visibleTexts.add('Welcome');
    final events = await run([flow('- assertVisible: Welcome\n- inputText: hi\n', name: 'pass.yaml')]);
    expect(events.first, isA<RunStarted>());
    expect(events.last, isA<RunFinished>());
    expect(steps(events).map((s) => (s.stepId, s.status)), [('1', StepStatus.passed), ('2', StepStatus.passed)]);
    expect(finished(events, 'pass').status, FlowStatus.passed);
    expect((events.last as RunFinished).isSuccess, isTrue);
    expect(session.calls, ['prepareDevice', 'start']);
  });

  test('a failed step stops the flow, skips the rest and saves artifacts', () async {
    agent.on[QaMethod.enterText] = (_) {
      session.logLines.add('typed');
      return {'node': null, 'value': 'a'};
    };
    final events = await run([flow('- inputText: a\n- assertVisible: Missing\n- inputText: b\n', name: 'fail.yaml')]);
    final s = steps(events);
    expect(s.map((e) => e.status), [StepStatus.passed, StepStatus.failed, StepStatus.skipped]);
    final failed = s[1];
    expect(failed.error!.code, 'not_found');
    expect(failed.artifacts, [
      p.join('flows', 'fail', 'screenshots', 'failure-2.png'),
      p.join('flows', 'fail', 'elements-2.json'),
    ]);
    for (final a in failed.artifacts) {
      expect(File(p.join(runDir.path, a)).existsSync(), isTrue, reason: a);
    }
    expect(failed.logTail, contains('typed'));
    expect(finished(events, 'fail').status, FlowStatus.failed);
    expect((events.last as RunFinished).isSuccess, isFalse);
  });

  test('an optional failure warns and the flow passes', () async {
    final events = await run([
      flow('- assertVisible:\n    text: Missing\n    optional: true\n- inputText: x\n', name: 'opt.yaml'),
    ]);
    expect(steps(events).map((e) => e.status), [StepStatus.warned, StepStatus.passed]);
    expect(finished(events, 'opt').status, FlowStatus.passed);
  });

  test('onFlowStart failure skips the body; onFlowComplete still runs', () async {
    final events = await run([
      flow(
        'onFlowStart:\n  - assertVisible: Missing\nonFlowComplete:\n  - inputText: cleanup\n---\n- inputText: body\n',
        name: 'hooks.yaml',
      ),
    ]);
    expect(steps(events).map((e) => (e.stepId, e.status)), [
      ('start.1', StepStatus.failed),
      ('1', StepStatus.skipped),
      ('complete.1', StepStatus.passed),
    ]);
    expect(typed(), ['cleanup']);
    expect(finished(events, 'hooks').status, FlowStatus.failed);
  });

  test('an onFlowComplete failure fails a passing flow', () async {
    final events = await run([
      flow('onFlowComplete:\n  - assertVisible: Missing\n---\n- inputText: body\n', name: 'late.yaml'),
    ]);
    expect(finished(events, 'late').status, FlowStatus.failed);
  });

  test('the app is reset before every flow after the first', () async {
    await run([flow('- inputText: a\n', name: 'a.yaml'), flow('- inputText: b\n', name: 'b.yaml')]);
    expect(session.calls, ['prepareDevice', 'start', 'reset']);
  });

  test('launchApp is a no-op on a fresh app and resets otherwise', () async {
    final events = await run([flow('- launchApp\n- inputText: a\n- launchApp\n', name: 'launch.yaml')]);
    final s = steps(events);
    expect(s[0].note, 'app already fresh');
    expect(s[2].note, isNull);
    expect(session.calls, ['prepareDevice', 'start', 'reset']);
  });

  test('clearState resets with the hook; an app without one fails the step', () async {
    await run([flow('- clearState\n', name: 'clear.yaml')]);
    expect(session.calls, ['prepareDevice', 'start', 'reset(clearState)']);

    session = FakeAppSession(agent)..failReset = QaException(QaErrorCode.unsupported, 'no reset hook');
    final events = await run([flow('- clearState\n', name: 'nohook.yaml')]);
    expect(steps(events).single.error!.code, 'unsupported');
    expect(finished(events, 'nohook').status, FlowStatus.failed);
  });

  test('runFlow when: skipped when the condition fails, nested otherwise', () async {
    const yaml =
        '- runFlow:\n    when:\n      visible: Banner\n    commands:\n      - inputText: inner\n- inputText: outer\n';
    var events = await run([flow(yaml, name: 'when.yaml')]);
    expect(steps(events).first.note, 'condition not met');
    expect(typed(), ['outer']);

    agent.sent.clear();
    agent.visibleTexts.add('Banner');
    events = await run([flow(yaml, name: 'when2.yaml')]);
    expect(steps(events).map((e) => e.stepId), ['1.1', '1', '2']);
    expect(typed(), ['inner', 'outer']);
  });

  test('variables: runFlow env, then CLI env, then the flow header', () async {
    files.write('sub/greet.yaml', 'env:\n  WHO: subflow-default\n---\n- inputText: \${GREETING} \${WHO}\n');
    final main = flow(
      'env:\n  GREETING: hello\n  WHO: header\n---\n'
      '- runFlow: sub/greet.yaml\n'
      '- runFlow:\n    file: sub/greet.yaml\n    env:\n      WHO: runflow\n'
      '- inputText: \${WHO}\n',
      name: 'vars.yaml',
    );
    await run([main], env: {'GREETING': 'hi'});
    expect(typed(), ['hi subflow-default', 'hi runflow', 'header']);
  });

  test('a runFlow path with a variable is parsed when it runs', () async {
    files.write('lazy/target.yaml', '- inputText: lazy\n');
    await run([flow('- runFlow: lazy/\${NAME}.yaml\n', name: 'lazy.yaml')], env: {'NAME': 'target'});
    expect(typed(), ['lazy']);
  });

  test('repeat runs its commands with nested ids; a while loop stops at the cap', () async {
    var events = await run([flow('- repeat:\n    times: 2\n    commands:\n      - inputText: x\n', name: 'rep.yaml')]);
    expect(steps(events).map((e) => e.stepId), ['1.1.1', '1.2.1', '1']);
    expect(steps(events).last.note, '2 iteration(s)');

    agent.visibleTexts.add('Forever');
    events = await run([
      flow('- repeat:\n    while:\n      visible: Forever\n    commands:\n      - inputText: x\n', name: 'loop.yaml'),
    ]);
    final loop = steps(events).last;
    expect(loop.stepId, '1');
    expect(loop.status, StepStatus.failed);
    expect(loop.error!.message, contains('repeat limit'));
  });

  test('a flow that passes on a retry is flaky', () async {
    session.onReset = () => agent.visibleTexts.add('Ready');
    final events = await run([flow('- assertVisible: Ready\n', name: 'flaky.yaml')], retries: 1);
    expect(events.whereType<FlowStarted>().map((e) => e.attempt), [1, 2]);
    expect(finished(events, 'flaky').status, FlowStatus.flaky);
    expect(finished(events, 'flaky').attempts, 2);
    expect(session.calls, ['prepareDevice', 'start', 'reset']);
    expect((events.last as RunFinished).isSuccess, isTrue);
  });

  test('a launch failure reports every flow as not run', () async {
    session.failStart = LaunchException('no devices found');
    final events = await run([flow('- inputText: a\n', name: 'a.yaml'), flow('- inputText: b\n', name: 'b.yaml')]);
    expect(events.whereType<FlowFinished>().map((e) => e.status), [FlowStatus.notRun, FlowStatus.notRun]);
    expect((events.last as RunFinished).error, contains('no devices found'));
  });

  test('a lost connection mid-flow errors that flow and skips the rest', () async {
    agent.on[QaMethod.enterText] = (_) =>
        throw QaException(QaErrorCode.internal, 'Service connection disposed', details: {'rpcCode': -32010});
    final events = await run([flow('- inputText: a\n', name: 'a.yaml'), flow('- inputText: b\n', name: 'b.yaml')]);
    expect(events.whereType<FlowFinished>().map((e) => e.status), [FlowStatus.error, FlowStatus.notRun]);
    expect((events.last as RunFinished).error, contains('Service connection disposed'));

    // The in-flight step is recorded as failed, not left with no
    // StepFinished at all.
    final failed = steps(events).single;
    expect(failed.stepId, '1');
    expect(failed.status, StepStatus.failed);
    expect(failed.error?.code, 'internal');
    expect(failed.error?.message, 'Service connection disposed');

    // The run error names the step, not just the bare exception message.
    expect((events.last as RunFinished).error, 'step 1 (inputText "a"): Service connection disposed');
  });

  test('an infrastructure error inside a runFlow subflow records the nested step and propagates', () async {
    agent.on[QaMethod.enterText] = (_) =>
        throw QaException(QaErrorCode.internal, 'Service connection disposed', details: {'rpcCode': -32010});
    final events = await run([flow('- runFlow:\n    commands:\n      - inputText: a\n', name: 'nested.yaml')]);
    expect(steps(events).map((e) => (e.stepId, e.status)), [('1.1', StepStatus.failed), ('1', StepStatus.failed)]);
    expect(steps(events).first.error?.code, 'internal');
    expect(steps(events).first.error?.message, 'Service connection disposed');
    expect(finished(events, 'nested').status, FlowStatus.error);
    expect((events.last as RunFinished).error, 'step 1.1 (inputText "a"): Service connection disposed');
  });

  test('an undefined variable fails the step with bad_request', () async {
    final events = await run([flow('- inputText: \${NOPE}\n', name: 'undef.yaml')]);
    final error = steps(events).single.error!;
    expect(error.code, 'bad_request');
    expect(error.message, contains('undefined variable NOPE'));
  });

  test('stopApp stops the app until launchApp starts it again', () async {
    var events = await run([flow('- stopApp\n- inputText: a\n', name: 'stopped.yaml')]);
    expect(steps(events)[1].error!.message, contains('not running'));

    session = FakeAppSession(agent);
    events = await run([flow('- stopApp\n- launchApp\n- inputText: a\n', name: 'restart.yaml')]);
    expect(session.calls, ['prepareDevice', 'start', 'stop', 'start']);
    expect(finished(events, 'restart').status, FlowStatus.passed);
  });

  test('--screenshots all captures after every UI step', () async {
    final events = await run([
      flow('- inputText: a\n- inputText: b\n', name: 'shots.yaml'),
    ], screenshots: ScreenshotPolicy.all);
    expect(steps(events).map((e) => e.artifacts.single), [
      p.join('flows', 'shots', 'screenshots', 'step-1.png'),
      p.join('flows', 'shots', 'screenshots', 'step-2.png'),
    ]);
  });

  group('stop', () {
    Map<String, Object?> typedValue(Map<String, Object?> args) => {'node': fakeNode().toJson(), 'value': args['text']};

    test('finishes the step in flight, skips the rest and runs no later flow', () async {
      final runner = FlowRunner(
        session: session,
        flows: [
          flow('- inputText: a\n- inputText: b\n- inputText: c\n', name: 'one.yaml'),
          flow('- inputText: d\n', name: 'two.yaml'),
        ],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1', retries: 1),
      );
      agent.on[QaMethod.enterText] = (args) {
        if (args['text'] == 'b') runner.stop();
        return typedValue(args);
      };
      final events = await runner.run().toList();
      expect(steps(events).map((s) => (s.stepId, s.status)), [
        ('1', StepStatus.passed),
        ('2', StepStatus.passed),
        ('3', StepStatus.skipped),
      ]);
      expect(finished(events, 'one').status, FlowStatus.error);
      expect(finished(events, 'one').attempts, 1);
      expect(finished(events, 'two').status, FlowStatus.notRun);
      final done = events.last as RunFinished;
      expect(done.error, FlowRunner.stoppedMessage);
      expect(done.isSuccess, isFalse);
      expect(typed(), ['a', 'b']);
    });

    test('inside runFlow skips the remaining children and marks the runFlow step stopped', () async {
      final runner = FlowRunner(
        session: session,
        flows: [
          flow(
            '- runFlow:\n    commands:\n      - inputText: a\n      - inputText: b\n- inputText: c\n',
            name: 'nested.yaml',
          ),
        ],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1'),
      );
      agent.on[QaMethod.enterText] = (args) {
        if (args['text'] == 'a') runner.stop();
        return typedValue(args);
      };
      final events = await runner.run().toList();
      expect(steps(events).map((s) => (s.stepId, s.status, s.note)), [
        ('1.1', StepStatus.passed, null),
        ('1.2', StepStatus.skipped, null),
        ('1', StepStatus.skipped, 'stopped'),
        ('2', StepStatus.skipped, null),
      ]);
      expect(finished(events, 'nested').status, FlowStatus.error);
    });

    test('prevents a retry', () async {
      final runner = FlowRunner(
        session: session,
        flows: [flow('- assertVisible: Missing\n', name: 'fails.yaml')],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1', retries: 2),
      );
      agent.on[QaMethod.find] = (args) {
        runner.stop();
        return {'nodes': <Object?>[]};
      };
      final events = await runner.run().toList();
      expect(finished(events, 'fails').status, FlowStatus.failed);
      expect(finished(events, 'fails').attempts, 1);
      expect(session.calls.where((c) => c == 'reset'), isEmpty);
      expect((events.last as RunFinished).error, FlowRunner.stoppedMessage);
    });

    test('after the last step leaves a passing run passing', () async {
      final runner = FlowRunner(
        session: session,
        flows: [flow('- inputText: a\n', name: 'last.yaml')],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1'),
      );
      agent.on[QaMethod.enterText] = (args) {
        runner.stop();
        return typedValue(args);
      };
      final events = await runner.run().toList();
      expect(finished(events, 'last').status, FlowStatus.passed);
      expect((events.last as RunFinished).isSuccess, isTrue);
    });

    test('while the device is being prepared skips the start', () async {
      final runner = FlowRunner(
        session: session,
        flows: [flow('- inputText: a\n', name: 'one.yaml')],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1'),
      );
      session.boots = DeviceInfo(platform: DevicePlatform.android, name: 'pixel', id: 'pixel', booted: false);
      session.onPrepare = runner.stop;
      final events = await runner.run().toList();
      expect(session.calls, ['prepareDevice']);
      expect(finished(events, 'one').status, FlowStatus.notRun);
      expect((events.last as RunFinished).error, FlowRunner.stoppedMessage);
    });

    test('from onBooting skips the start', () async {
      final runner = FlowRunner(
        session: session,
        flows: [flow('- inputText: a\n', name: 'one.yaml')],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1'),
      );
      session.boots = DeviceInfo(platform: DevicePlatform.android, name: 'pixel', id: 'pixel', booted: false);
      final events = <RunEvent>[];
      await for (final e in runner.run()) {
        events.add(e);
        if (e is DeviceBooting) runner.stop();
      }
      expect(session.calls, ['prepareDevice']);
      expect((events.last as RunFinished).error, FlowRunner.stoppedMessage);
    });

    test('before run() is listened to skips the launch and marks every flow notRun', () async {
      final runner = FlowRunner(
        session: session,
        flows: [
          flow('- inputText: a\n', name: 'one.yaml'),
          flow('- inputText: b\n', name: 'two.yaml'),
        ],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1'),
      );
      runner.stop();
      final events = await runner.run().toList();
      expect(session.calls, isEmpty);
      expect(finished(events, 'one').status, FlowStatus.notRun);
      expect(finished(events, 'two').status, FlowStatus.notRun);
      expect((events.last as RunFinished).error, FlowRunner.stoppedMessage);
      expect((events.last as RunFinished).isSuccess, isFalse);
    });
  });

  test('runIdFor and slugify', () {
    expect(runIdFor(DateTime.utc(2026, 9, 29, 7, 5, 3)), '20260929-070503');
    expect(FlowRunner.slugify('Log in / out!'), 'log-in-out');
    expect(FlowRunner.slugify('***'), 'flow');
  });

  group('preview', () {
    test('emits an in-memory screenshot after each UI step and writes no file for it', () async {
      agent.visibleTexts.add('Welcome');
      final runner = FlowRunner(
        session: session,
        flows: [flow('- launchApp\n- assertVisible: Welcome\n- assertVisible: Missing\n', name: 'p.yaml')],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1', preview: true),
      );
      final events = await runner.run().toList();
      final previews = events.whereType<StepPreview>().toList();
      expect(previews.map((e) => e.stepId), ['2', '3']);
      expect(previews.first.png, pngBytes);
      final shots = Directory(p.join(runDir.path, 'flows', 'p', 'screenshots')).listSync();
      expect(shots.map((f) => p.basename(f.path)), ['failure-3.png']);
    });

    test('is off by default', () async {
      agent.visibleTexts.add('Welcome');
      final events = await run([flow('- assertVisible: Welcome\n', name: 'off.yaml')]);
      expect(events.whereType<StepPreview>(), isEmpty);
    });

    test('turning it off during a run applies to every later preview', () async {
      final runner = FlowRunner(
        session: session,
        flows: [flow('- inputText: a\n- inputText: b\n', name: 't.yaml')],
        options: FlowRunOptions(runDir: runDir.path, runId: 'r1', preview: true),
      );
      agent.on[QaMethod.enterText] = (args) {
        if (args['text'] == 'a') runner.preview = false;
        return {'node': fakeNode().toJson(), 'value': args['text']};
      };
      final events = await runner.run().toList();
      expect(events.whereType<StepPreview>(), isEmpty);
    });
  });
}
