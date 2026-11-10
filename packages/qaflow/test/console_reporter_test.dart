import 'dart:typed_data';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  const flow = FlowInfo(name: 'Login', file: '/x/login.yaml', slug: 'login');

  test('prints steps, failures, flow results and a summary', () {
    final out = StringBuffer();
    final r = ConsoleReporter(out);
    for (final e in <RunEvent>[
      RunStarted(runId: 'r1', project: 'demo', mode: 'debug', flows: const [flow]),
      FlowStarted(flow: flow, attempt: 1),
      StepFinished(
        flow: flow,
        stepId: '1',
        label: 'tapOn id: go',
        command: 'tapOn',
        status: StepStatus.passed,
        duration: const Duration(milliseconds: 12),
      ),
      StepFinished(
        flow: flow,
        stepId: '2.1',
        label: 'inputText "a"',
        command: 'inputText',
        status: StepStatus.passed,
        duration: const Duration(milliseconds: 3),
      ),
      StepFinished(
        flow: flow,
        stepId: '3',
        label: 'assertVisible text: "Hi"',
        command: 'assertVisible',
        status: StepStatus.failed,
        duration: const Duration(seconds: 10),
        error: const StepError('not_found', 'nothing matches'),
      ),
      StepFinished(
        flow: flow,
        stepId: '4',
        label: 'scroll',
        command: 'scroll',
        status: StepStatus.skipped,
        duration: Duration.zero,
      ),
      AppLog(line: 'noise'),
      FlowFinished(flow: flow, status: FlowStatus.failed, duration: const Duration(milliseconds: 10500), attempts: 1),
      RunFinished(duration: const Duration(seconds: 11), counts: const {FlowStatus.failed: 1}),
    ]) {
      r.onEvent(e);
    }
    final text = out.toString();
    expect(text, contains('Running 1 flow(s) against demo (debug)'));
    expect(text, contains('FLOW Login'));
    expect(text, contains('  PASS 1 tapOn id: go (12 ms)'));
    expect(text, contains('    PASS 2.1 inputText "a" (3 ms)'));
    expect(text, contains('  FAIL 3 assertVisible text: "Hi" (10000 ms)'));
    expect(text, contains('       not_found: nothing matches'));
    expect(text, contains('  SKIP 4 scroll'));
    expect(text, contains('  => FAILED in 10.5 s'));
    expect(text, contains('0 passed, 1 failed, 0 flaky, 0 errors, 0 not run'));
    expect(text, isNot(contains('noise')));

    final verbose = StringBuffer();
    ConsoleReporter(verbose, verbose: true).onEvent(AppLog(line: 'noise'));
    expect(verbose.toString(), contains('[app] noise'));
  });

  test('a run error is printed', () {
    final out = StringBuffer();
    ConsoleReporter(
      out,
    ).onEvent(RunFinished(duration: Duration.zero, counts: const {FlowStatus.notRun: 2}, error: 'no devices found'));
    expect(out.toString(), contains('Run stopped: no devices found'));
  });

  test('a flow that never got a FLOW header is named on its own line, not left anonymous', () {
    const other = FlowInfo(name: 'Logout', file: '/x/logout.yaml', slug: 'logout');

    final notRun = StringBuffer();
    ConsoleReporter(notRun)
      ..onEvent(RunStarted(runId: 'r1', project: 'demo', mode: 'debug', flows: const [other]))
      ..onEvent(FlowFinished(flow: other, status: FlowStatus.notRun, duration: Duration.zero, attempts: 0));
    expect(notRun.toString(), contains('NOT RUN Logout'));
    expect(notRun.toString(), isNot(contains('=>')));

    final error = StringBuffer();
    ConsoleReporter(error)
      ..onEvent(RunStarted(runId: 'r1', project: 'demo', mode: 'debug', flows: const [other]))
      ..onEvent(FlowFinished(flow: other, status: FlowStatus.error, duration: Duration.zero, attempts: 0));
    expect(error.toString(), contains('ERROR Logout'));
    expect(error.toString(), isNot(contains('=>')));
  });

  test('ignores preview events', () {
    final out = StringBuffer();
    ConsoleReporter(out).onEvent(StepPreview(flow: flow, stepId: '1', png: Uint8List(0)));
    expect(out.toString(), isEmpty);
  });

  test('the device is announced while booting and when ready', () {
    final out = StringBuffer();
    final r = ConsoleReporter(out);
    final device = const DeviceInfo(
      platform: DevicePlatform.ios,
      name: 'iPhone 17 Pro',
      id: 'U1',
      osVersion: 'iOS 26.5',
    );
    r.onEvent(DeviceBooting(device: device));
    r.onEvent(DeviceReady(device: device));
    expect(out.toString(), contains('Booting iPhone 17 Pro (iOS 26.5)…'));
    expect(out.toString(), contains('Device: iPhone 17 Pro (iOS 26.5)'));
  });

  test('screenshot comparisons print their outcome without timing', () {
    final out = StringBuffer();
    final r = ConsoleReporter(out);
    const cmp = ScreenshotComparison(
      name: 'dialog-open',
      baselinePath: '.qa/baselines/d/login/dialog-open.png',
      deviceKey: 'd',
      outcome: ComparisonOutcome.failed,
      mismatchPercent: 2.31,
      threshold: 0.1,
      actual: 'a.png',
    );
    r.onEvent(
      StepFinished(
        flow: flow,
        stepId: '7',
        label: 'assertScreenshot dialog-open',
        command: 'assertScreenshot',
        status: StepStatus.failed,
        duration: const Duration(milliseconds: 40),
        error: const StepError('screenshot_mismatch', '2.31% of pixels differ (threshold 0.1%)'),
        comparison: cmp,
      ),
    );
    r.onEvent(
      StepFinished(
        flow: flow,
        stepId: '7',
        label: 'assertScreenshot dialog-open',
        command: 'assertScreenshot',
        status: StepStatus.warned,
        duration: const Duration(milliseconds: 40),
        note: 'baseline recorded',
        comparison: const ScreenshotComparison(
          name: 'dialog-open',
          baselinePath: '.qa/baselines/d/login/dialog-open.png',
          deviceKey: 'd',
          outcome: ComparisonOutcome.recorded,
          threshold: 0.1,
          actual: 'a.png',
        ),
      ),
    );
    final lines = out.toString().split('\n');
    expect(lines[0], '  FAIL 7 assertScreenshot dialog-open (2.31% of pixels differ, threshold 0.1%)');
    expect(lines[1], '  WARN 7 assertScreenshot dialog-open - baseline recorded');
    expect(out.toString(), isNot(contains('screenshot_mismatch')));
  });
}
