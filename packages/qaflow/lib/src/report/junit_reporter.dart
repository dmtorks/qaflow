import 'dart:io';

import 'package:path/path.dart' as p;

import '../flow/events.dart';
import 'comparison_text.dart';
import 'results.dart';

final RegExp _invalidXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

String _text(String s) =>
    s.replaceAll(_invalidXml, '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _attr(String s) => _text(s).replaceAll('"', '&quot;').replaceAll("'", '&apos;').replaceAll('\n', '&#10;');

String _seconds(int ms) => (ms / 1000).toStringAsFixed(3);

/// JUnit XML in the subset GitHub, GitLab and Jenkins all read: one suite
/// per run, one testcase per flow, screenshots as `[[ATTACHMENT|path]]`
/// lines in system-out.
String renderJunit(RunResult r, {required String runDir, String? workingDirectory}) {
  final cwd = workingDirectory ?? Directory.current.path;
  String rel(String path) => p.relative(path, from: cwd);
  final s = r.summary;
  final counts =
      'tests="${s['total']}" failures="${s['failed']}" errors="${s['error']}" skipped="${s['notRun']}" time="${_seconds(r.durationMs)}"';
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites name="qa" $counts>')
    ..writeln('  <testsuite name="${_attr(r.project)}" $counts timestamp="${r.startedAt.toUtc().toIso8601String()}">');
  if (r.device != null) {
    b
      ..writeln('    <properties>')
      ..writeln('      <property name="device" value="${_attr(r.device!.title)}"/>')
      ..writeln('    </properties>');
  }
  for (final f in r.flows) {
    b.writeln(
      '    <testcase name="${_attr(f.name)}" classname="${_attr(rel(f.file))}" time="${_seconds(f.durationMs)}">',
    );
    final last = f.attempts.isEmpty ? null : f.attempts.last;
    StepResult? failed;
    for (final step in last?.steps ?? const <StepResult>[]) {
      if (step.status == StepStatus.failed) {
        failed = step;
        break;
      }
    }
    switch (f.status) {
      case FlowStatus.failed:
        final detail = mismatchDetail(failed?.error);
        final message = failed == null
            ? 'flow failed'
            : detail != null
            ? '${failed.label} ($detail)'
            : '${failed.label}: ${failed.error?.message ?? 'failed'}';
        final type = failed?.error?.code ?? 'failed';
        b.writeln(
          '      <failure message="${_attr(message)}" type="${_attr(type)}">${_text(_details(failed))}</failure>',
        );
      case FlowStatus.error:
        b.writeln(
          '      <error message="${_attr(r.error ?? 'infrastructure error')}" type="error">${_text(_details(failed))}</error>',
        );
      case FlowStatus.notRun:
        b.writeln('      <skipped message="not run"/>');
      case FlowStatus.passed || FlowStatus.flaky:
        break;
    }
    final out = _systemOut(f, runDir, rel);
    if (out.isNotEmpty) b.writeln('      <system-out>${_text(out)}</system-out>');
    b.writeln('    </testcase>');
  }
  b
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return b.toString();
}

String _details(StepResult? step) {
  if (step == null) return '';
  return [
    'step ${step.id}: ${step.label}',
    if (step.error != null) '${step.error!.code}: ${step.error!.message}',
    if (step.logTail.isNotEmpty) ...['', 'app output:', ...step.logTail],
  ].join('\n');
}

String _systemOut(FlowResult f, String runDir, String Function(String) rel) {
  final lines = <String>[];
  if (f.status == FlowStatus.flaky) lines.add('passed on attempt ${f.attempts.length}');
  for (final a in f.attempts) {
    lines.add('attempt ${a.attempt}: ${a.status}');
    for (final s in a.steps) {
      lines.add('  ${s.status.name.toUpperCase()} ${s.id} ${s.label} (${s.durationMs} ms)');
      if (s.error != null) lines.add('    ${s.error!.code}: ${s.error!.message}');
      final c = s.comparison;
      for (final artifact in {...s.artifacts, ?c?.baseline, ?c?.actual, ?c?.diff}) {
        if (artifact.toLowerCase().endsWith('.png')) {
          lines.add('[[ATTACHMENT|${rel(p.join(runDir, artifact))}]]');
        }
      }
    }
  }
  return lines.join('\n');
}

/// Writes `junit.xml` into [runDir] and returns its path.
String writeJunit(RunResult r, String runDir, {String? workingDirectory}) {
  final file = File(p.join(runDir, 'junit.xml'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(renderJunit(r, runDir: runDir, workingDirectory: workingDirectory));
  return file.path;
}
