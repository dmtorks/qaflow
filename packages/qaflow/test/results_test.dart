import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  const login = FlowInfo(name: 'Login', file: '/x/login.yaml', slug: 'login', tags: ['smoke']);
  const list = FlowInfo(name: 'List', file: '/x/list.yaml', slug: 'list');
  const later = FlowInfo(name: 'Later', file: '/x/later.yaml', slug: 'later');
  final t0 = DateTime.utc(2026, 9, 29, 12);

  StepFinished step(FlowInfo f, String id, StepStatus status, {StepError? error, List<String> artifacts = const []}) =>
      StepFinished(
        flow: f,
        stepId: id,
        label: 'step $id',
        command: 'tapOn',
        status: status,
        duration: const Duration(milliseconds: 5),
        error: error,
        artifacts: artifacts,
      );

  List<RunEvent> events() => [
    RunStarted(runId: 'r1', project: 'demo', mode: 'debug', flows: const [login, list, later], time: t0),
    FlowStarted(flow: login, attempt: 1),
    step(
      login,
      '1',
      StepStatus.failed,
      error: const StepError('not_found', 'nope'),
      artifacts: const ['flows/login/screenshots/failure-1.png'],
    ),
    FlowStarted(flow: login, attempt: 2),
    step(login, '1', StepStatus.passed),
    FlowFinished(flow: login, status: FlowStatus.flaky, duration: const Duration(milliseconds: 1500), attempts: 2),
    FlowStarted(flow: list, attempt: 1),
    step(list, '1', StepStatus.passed),
    step(list, '2', StepStatus.failed, error: const StepError('not_found', 'gone')),
    step(list, '3', StepStatus.skipped),
    FlowFinished(flow: list, status: FlowStatus.failed, duration: const Duration(seconds: 2), attempts: 1),
    FlowFinished(flow: later, status: FlowStatus.notRun, duration: Duration.zero, attempts: 0),
    AppLog(line: 'ignored'),
    RunFinished(duration: const Duration(seconds: 4), counts: const {}, error: 'lost connection'),
  ];

  RunResult build() {
    final b = RunResultBuilder();
    events().forEach(b.add);
    return b.build();
  }

  test('the builder groups steps into attempts and flows', () {
    final r = build();
    expect(r.runId, 'r1');
    expect(r.startedAt, t0);
    expect(r.durationMs, 4000);
    expect(r.error, 'lost connection');
    expect(r.flows.map((f) => f.status), [FlowStatus.flaky, FlowStatus.failed, FlowStatus.notRun]);
    final loginResult = r.flows.first;
    expect(loginResult.tags, ['smoke']);
    expect(loginResult.attempts.map((a) => a.status), ['failed', 'passed']);
    expect(loginResult.attempts.first.steps.single.artifacts, ['flows/login/screenshots/failure-1.png']);
    expect(r.flows[1].attempts.single.steps.map((s) => s.status), [
      StepStatus.passed,
      StepStatus.failed,
      StepStatus.skipped,
    ]);
    expect(r.flows.last.attempts, isEmpty);
    expect(r.summary, {'total': 3, 'passed': 0, 'failed': 1, 'flaky': 1, 'error': 0, 'notRun': 1});
  });

  test('a subflow step comes before its children, though it finishes after them', () {
    final b = RunResultBuilder()
      ..add(RunStarted(runId: 'r2', project: 'demo', mode: 'debug', flows: const [login], time: t0))
      ..add(FlowStarted(flow: login, attempt: 1));
    for (final id in ['1', '2.1', '2.2.1', '2.2', '2.10', '2', '10', '3']) {
      b.add(step(login, id, StepStatus.passed));
    }
    final steps = b.build().flows.single.attempts.single.steps;
    expect(steps.map((s) => s.id), ['1', '2', '2.1', '2.2', '2.2.1', '2.10', '3', '10']);
  });

  test('hook steps sort before and after the body at every level', () {
    final b = RunResultBuilder()
      ..add(RunStarted(runId: 'r3', project: 'demo', mode: 'debug', flows: const [login], time: t0))
      ..add(FlowStarted(flow: login, attempt: 1));
    for (final id in ['start.1', '1', '2.start.1', '2.1', '2.complete.1', '2', 'complete.1']) {
      b.add(step(login, id, StepStatus.passed));
    }
    // Finish order puts the runFlow parent 2 after its children; run order puts it first.
    final steps = b.build().flows.single.attempts.single.steps;
    expect(steps.map((s) => s.id), ['start.1', '1', '2', '2.start.1', '2.1', '2.complete.1', 'complete.1']);
  });

  test('an id part that is neither a number nor a hook leaves the steps in finish order', () {
    final b = RunResultBuilder()
      ..add(RunStarted(runId: 'r4', project: 'demo', mode: 'debug', flows: const [login], time: t0))
      ..add(FlowStarted(flow: login, attempt: 1));
    for (final id in ['2.1', 'x', '2']) {
      b.add(step(login, id, StepStatus.passed));
    }
    expect(b.build().flows.single.attempts.single.steps.map((s) => s.id), ['2.1', 'x', '2']);
  });

  test('results.json written in finish order reads back in run order', () {
    final json = {
      'attempt': 1,
      'status': 'passed',
      'steps': [
        for (final id in ['1', '2.1', '2.2', '2', '3'])
          {'id': id, 'label': 'step $id', 'command': 'tapOn', 'status': 'passed', 'durationMs': 1},
      ],
    };
    expect(AttemptResult.fromJson(json).steps.map((s) => s.id), ['1', '2', '2.1', '2.2', '3']);
  });

  test('JSON round trip', () {
    final r = build();
    final json = jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>;
    expect(json['schemaVersion'], 1);
    expect(RunResult.fromJson(json).toJson(), r.toJson());
  });

  test('writeResultsJson writes results.json in the run folder', () {
    final dir = Directory.systemTemp.createTempSync('qa_results');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = writeResultsJson(build(), dir.path);
    expect(path, p.join(dir.path, 'results.json'));
    expect((jsonDecode(File(path).readAsStringSync()) as Map)['runId'], 'r1');
  });

  test('the device round-trips through results.json and is optional', () {
    final builder = RunResultBuilder()
      ..add(RunStarted(runId: 'r', project: 'p', mode: 'debug', flows: const []))
      ..add(
        DeviceReady(
          device: const DeviceInfo(
            platform: DevicePlatform.android,
            name: 'qa_pixel_api34',
            id: 'emulator-5554',
            osVersion: 'Android 14 (API 34)',
          ),
        ),
      )
      ..add(RunFinished(duration: Duration.zero, counts: const {}));
    final result = builder.build();
    final json = result.toJson();
    expect(json['device'], {
      'platform': 'android',
      'name': 'qa_pixel_api34',
      'id': 'emulator-5554',
      'osVersion': 'Android 14 (API 34)',
    });
    expect(RunResult.fromJson(json).device?.title, 'qa_pixel_api34 (Android 14 (API 34))');
    expect(RunResult.fromJson(sampleResult().toJson()).device, isNull);
  });

  test('a step comparison is carried into results.json and round-trips', () {
    const comparison = ScreenshotComparison(
      name: 'home',
      baselinePath: '.qa/baselines/macos/login/home.png',
      deviceKey: 'macos',
      outcome: ComparisonOutcome.failed,
      mismatchPercent: 6.25,
      threshold: 0.1,
      actual: 'flows/login/screenshots/home.actual.png',
      baseline: 'flows/login/screenshots/home.baseline.png',
      diff: 'flows/login/screenshots/home.diff.png',
    );
    final builder = RunResultBuilder()
      ..add(RunStarted(runId: 'r', project: 'p', mode: 'debug', flows: const [login]))
      ..add(FlowStarted(flow: login, attempt: 1))
      ..add(
        StepFinished(
          flow: login,
          stepId: '1',
          label: 'assertScreenshot home',
          command: 'assertScreenshot',
          status: StepStatus.failed,
          duration: Duration.zero,
          comparison: comparison,
        ),
      )
      ..add(step(login, '2', StepStatus.skipped))
      ..add(FlowFinished(flow: login, status: FlowStatus.failed, duration: Duration.zero, attempts: 1))
      ..add(RunFinished(duration: Duration.zero, counts: const {}));
    final steps = builder.build().flows.single.attempts.single.steps;
    expect(steps[0].toJson()['comparison'], comparison.toJson());
    expect(steps[1].toJson().containsKey('comparison'), isFalse);
    final back = StepResult.fromJson(jsonDecode(jsonEncode(steps[0].toJson())) as Map<String, Object?>);
    expect(back.toJson(), steps[0].toJson());
    expect(back.comparison!.diff, 'flows/login/screenshots/home.diff.png');
  });
}
