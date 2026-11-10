import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  String render() => renderJunit(sampleResult(), runDir: '/work/qa-out/r1', workingDirectory: '/work');

  test('suite counts and timing', () {
    final xml = render();
    expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    expect(xml, contains('<testsuites name="qa" tests="3" failures="1" errors="0" skipped="1" time="4.200">'));
    expect(
      xml,
      contains(
        '<testsuite name="demo &lt;app&gt;" tests="3" failures="1" errors="0" skipped="1" time="4.200" timestamp="2026-09-29T12:00:00.000Z">',
      ),
    );
  });

  test('testcases, failure, skipped and attachments', () {
    final xml = render();
    expect(xml, contains('<testcase name="Login &amp; out" classname="flows/login.yaml" time="1.200">'));
    expect(
      xml,
      contains(
        '<failure message="assertVisible text: &quot;&lt;Item&gt;&quot;: nothing matches &quot;&lt;Item&gt;&quot; &amp; more" type="not_found">',
      ),
    );
    expect(xml, contains('<skipped message="not run"/>'));
    expect(xml, contains('[[ATTACHMENT|qa-out/r1/flows/list/screenshots/failure-2.png]]'));
    expect(xml, isNot(contains('[[ATTACHMENT|qa-out/r1/flows/list/elements-2.json]]')));
    expect(xml, contains('app said hi'));
  });

  test('the device is a suite property only when known', () {
    final xml = renderJunit(
      sampleResult(
        device: const DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17 Pro', id: 'U1', osVersion: 'iOS 26.5'),
      ),
      runDir: '/work/qa-out/r1',
      workingDirectory: '/work',
    );
    expect(xml, contains('<property name="device" value="iPhone 17 Pro (iOS 26.5)"/>'));
    expect(render(), isNot(contains('<property')));
  });

  test('control characters are stripped', () {
    final r = sampleResult();
    final dirty = RunResult(
      runId: r.runId,
      project: 'a\u0001b',
      mode: r.mode,
      startedAt: r.startedAt,
      durationMs: r.durationMs,
      flows: const [],
    );
    expect(renderJunit(dirty, runDir: '/w/r', workingDirectory: '/w'), contains('name="ab"'));
  });

  test('xmllint accepts the output', () {
    final dir = Directory.systemTemp.createTempSync('qa_junit');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = writeJunit(sampleResult(), dir.path, workingDirectory: dir.path);
    expect(path, p.join(dir.path, 'junit.xml'));
    final result = Process.runSync('xmllint', ['--noout', path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }, skip: Process.runSync('which', ['xmllint']).exitCode == 0 ? false : 'xmllint not installed');

  test('a failed screenshot comparison uses the console text and attaches its images once', () {
    final xml = renderJunit(
      resultWithStep(
        const StepResult(
          id: '7',
          label: 'assertScreenshot home',
          command: 'assertScreenshot',
          status: StepStatus.failed,
          durationMs: 5,
          error: StepError('screenshot_mismatch', '2.31% of pixels differ (threshold 0.1%)'),
          artifacts: [
            'flows/list/screenshots/home.actual.png',
            'flows/list/screenshots/home.baseline.png',
            'flows/list/screenshots/home.diff.png',
          ],
          comparison: ScreenshotComparison(
            name: 'home',
            baselinePath: '.qa/baselines/d/list/home.png',
            deviceKey: 'd',
            outcome: ComparisonOutcome.failed,
            mismatchPercent: 2.31,
            threshold: 0.1,
            actual: 'flows/list/screenshots/home.actual.png',
            baseline: 'flows/list/screenshots/home.baseline.png',
            diff: 'flows/list/screenshots/home.diff.png',
          ),
        ),
      ),
      runDir: '/work/qa-out/r1',
      workingDirectory: '/work',
    );
    expect(xml, contains('message="assertScreenshot home (2.31% of pixels differ, threshold 0.1%)"'));
    for (final k in ['baseline', 'actual', 'diff']) {
      final tag = '[[ATTACHMENT|qa-out/r1/flows/list/screenshots/home.$k.png]]';
      expect(tag.allMatches(xml).length, 1, reason: k);
    }
  });
}
