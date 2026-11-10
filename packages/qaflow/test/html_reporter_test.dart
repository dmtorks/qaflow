import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  test('the report lists every flow, opens failures and links screenshots', () {
    final html = renderHtml(sampleResult());
    expect(html, startsWith('<!DOCTYPE html>'));
    expect(html, contains('Login &amp; out'));
    expect(html, contains('<details class="flow failed" open>'));
    expect(html, contains('<details class="flow passed">'));
    expect(html, contains('src="flows/list/screenshots/failure-2.png"'));
    expect(html, contains('href="flows/list/elements-2.json"'));
    expect(html, contains('nothing matches &quot;&lt;Item&gt;&quot; &amp; more'));
    expect(html, contains('prefers-color-scheme: dark'));
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('<Item>')));
  });

  test('the device line shows only when the device is known', () {
    expect(
      renderHtml(
        sampleResult(
          device: const DeviceInfo(
            platform: DevicePlatform.ios,
            name: 'iPhone 17 Pro',
            id: 'U1',
            osVersion: 'iOS 26.5',
          ),
        ),
      ),
      contains('Device: iPhone 17 Pro (iOS 26.5)'),
    );
    expect(renderHtml(sampleResult()), isNot(contains('Device:')));
  });

  test('an error flow with no attempts shows the run error instead of "Not run."', () {
    final result = RunResult(
      runId: 'r2',
      project: 'demo',
      mode: 'debug',
      startedAt: DateTime.utc(2026, 9, 29, 12),
      durationMs: 500,
      error: 'step 2 (inputText "a"): Service connection disposed',
      flows: const [
        FlowResult(
          name: 'Logout',
          file: '/work/flows/logout.yaml',
          slug: 'logout',
          tags: [],
          status: FlowStatus.error,
          durationMs: 0,
          attempts: [],
        ),
      ],
    );
    final html = renderHtml(result);
    expect(html, isNot(contains('Not run.')));
    expect(
      'Service connection disposed'.allMatches(html).length,
      2,
      reason: 'once in the run banner, once in the flow',
    );
  });

  test('writeHtml writes report.html in the run folder', () {
    final dir = Directory.systemTemp.createTempSync('qa_html');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(writeHtml(sampleResult(), dir.path), p.join(dir.path, 'report.html'));
    expect(File(p.join(dir.path, 'report.html')).readAsStringSync(), contains('List'));
  });

  group('screenshot comparisons', () {
    RunResult withComparison(
      ScreenshotComparison c, {
      StepStatus status = StepStatus.failed,
      StepError? error,
      String? note,
    }) => resultWithStep(
      StepResult(
        id: '7',
        label: 'assertScreenshot ${c.name}',
        command: 'assertScreenshot',
        status: status,
        durationMs: 5,
        error: error,
        note: note,
        comparison: c,
        artifacts: [c.actual, ?c.baseline, ?c.diff],
      ),
    );

    test('a failed comparison links baseline, actual and diff in order', () {
      final html = renderHtml(
        withComparison(
          const ScreenshotComparison(
            name: 'home',
            baselinePath: '.qa/baselines/d/list/home.png',
            deviceKey: 'd',
            outcome: ComparisonOutcome.failed,
            mismatchPercent: 2.31,
            threshold: 0.1,
            actual: 'flows/list/screenshots/a&b.actual.png',
            baseline: 'flows/list/screenshots/a&b.baseline.png',
            diff: 'flows/list/screenshots/a&b.diff.png',
          ),
          error: const StepError('screenshot_mismatch', '2.31% of pixels differ (threshold 0.1%)'),
        ),
      );
      expect(html, contains('2.31% of pixels differ (threshold 0.1%)'));
      final links = RegExp(
        r'<a href="([^"]+)"><img [^>]*></a><figcaption>(\w+)</figcaption>',
      ).allMatches(html).toList();
      expect(links.map((m) => m[2]), ['Baseline', 'Actual', 'Diff']);
      expect(links[0][1], 'flows/list/screenshots/a&amp;b.baseline.png');
      expect(links[1][1], 'flows/list/screenshots/a&amp;b.actual.png');
      expect(links[2][1], 'flows/list/screenshots/a&amp;b.diff.png');
      expect(html, isNot(contains('a&b')));
      expect(html, isNot(contains('<script')));
    });

    test('percentages read as on the console', () {
      final html = renderHtml(
        withComparison(
          const ScreenshotComparison(
            name: 'home',
            baselinePath: '.qa/baselines/d/list/home.png',
            deviceKey: 'd',
            outcome: ComparisonOutcome.passed,
            mismatchPercent: 0.0,
            threshold: 1.0,
            actual: 'flows/list/screenshots/home.actual.png',
            baseline: 'flows/list/screenshots/home.baseline.png',
          ),
          status: StepStatus.passed,
        ),
      );
      expect(html, contains('screenshot passed, 0% of pixels differ (threshold 1%)'));
      expect(formatPercent(3.0), '3');
      expect(formatPercent(0.27), '0.27');
    });

    test('a recorded comparison shows only the actual image and the note', () {
      final html = renderHtml(
        withComparison(
          const ScreenshotComparison(
            name: 'home',
            baselinePath: '.qa/baselines/d/list/home.png',
            deviceKey: 'd',
            outcome: ComparisonOutcome.recorded,
            threshold: 0.1,
            actual: 'flows/list/screenshots/home.actual.png',
          ),
          status: StepStatus.warned,
          note: 'baseline recorded',
        ),
      );
      expect(html, contains('baseline recorded'));
      expect(RegExp('<figcaption>').allMatches(html).length, 1);
      expect(html, contains('<figcaption>Actual</figcaption>'));
      expect('home.actual.png'.allMatches(html).length, 2);
    });
  });
}
