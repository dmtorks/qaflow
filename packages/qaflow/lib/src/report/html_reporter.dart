import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../flow/events.dart';
import '../screenshot/image_compare.dart';
import '../screenshot/screenshot_comparison.dart';
import 'results.dart';

// Attribute mode escapes & < > and quotes but not '/', so relative links
// keep working; it is used for text too, where quotes are harmless.
const HtmlEscape _escape = HtmlEscape(HtmlEscapeMode.attribute);

String _h(String s) => _escape.convert(s);

const String _css = '''
:root { --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --card: #f5f5f7;
  --pass: #1a7f37; --fail: #cf222e; --warn: #9a6700; --skip: #6e6e73; --error: #8250df; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #111113; --fg: #f2f2f7; --muted: #a1a1a6; --line: #2c2c30; --card: #1c1c1f;
    --pass: #4ac26b; --fail: #ff7b72; --warn: #d4a72c; --skip: #8b8b90; --error: #b392f0; }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--fg);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1000px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
.meta { color: var(--muted); margin-bottom: 16px; }
.summary { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 24px; }
.pill { padding: 4px 10px; border-radius: 999px; background: var(--card); border: 1px solid var(--line); }
.flow { border: 1px solid var(--line); border-radius: 10px; margin-bottom: 12px; background: var(--card); }
.flow > summary { cursor: pointer; padding: 12px 14px; display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
.flow > div { padding: 0 14px 14px; overflow-x: auto; }
.badge { font-weight: 600; font-size: 12px; letter-spacing: .04em; text-transform: uppercase; }
.passed .badge, .s-passed { color: var(--pass); }
.failed .badge, .s-failed { color: var(--fail); }
.flaky .badge, .s-warned { color: var(--warn); }
.error .badge { color: var(--error); }
.notRun .badge, .s-skipped { color: var(--skip); }
.file { color: var(--muted); font-size: 13px; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
td, th { text-align: left; padding: 6px 8px; border-top: 1px solid var(--line); vertical-align: top; }
td.num { text-align: right; white-space: nowrap; color: var(--muted); }
.err { color: var(--fail); white-space: pre-wrap; }
pre { margin: 6px 0 0; font-size: 12px; white-space: pre-wrap; color: var(--muted); }
.shots { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 6px; }
.shots figure { margin: 0; }
.shots figcaption { font-size: 12px; color: var(--muted); }
.shots img { max-width: 240px; height: auto; border: 1px solid var(--line); border-radius: 6px; }
''';

void _comparison(StringBuffer b, ScreenshotComparison c) {
  final percent = c.mismatchPercent == null ? '' : ', ${formatPercent(c.mismatchPercent!)}% of pixels differ';
  b.writeln(
    '<div class="file">screenshot ${_h(c.outcome.name)}$percent (threshold ${formatPercent(c.threshold)}%)</div>',
  );
  b.writeln('<div class="shots">');
  for (final (caption, path) in [('Baseline', c.baseline), ('Actual', c.actual), ('Diff', c.diff)]) {
    if (path == null) continue;
    b.writeln(
      '<figure><a href="${_h(path)}"><img src="${_h(path)}" alt="${_h(caption)}" loading="lazy"></a>'
      '<figcaption>$caption</figcaption></figure>',
    );
  }
  b.writeln('</div>');
}

/// A static report, no JavaScript: summary, then one expandable section per
/// flow (open when it did not pass) with steps, errors and screenshots.
String renderHtml(RunResult r) {
  final s = r.summary;
  final b = StringBuffer()
    ..writeln('<!DOCTYPE html>')
    ..writeln('<html lang="en"><head><meta charset="utf-8">')
    ..writeln('<meta name="viewport" content="width=device-width, initial-scale=1">')
    ..writeln('<title>QA run ${_h(r.runId)}</title>')
    ..writeln('<style>$_css</style></head><body><main>')
    ..writeln('<h1>${_h(r.project)}: run ${_h(r.runId)}</h1>')
    ..writeln(
      '<div class="meta">${_h(r.mode)} mode, ${_h(r.startedAt.toUtc().toIso8601String())}, '
      '${(r.durationMs / 1000).toStringAsFixed(1)} s</div>',
    );
  if (r.device != null) b.writeln('<div class="meta">Device: ${_h(r.device!.title)}</div>');
  if (r.error != null) b.writeln('<p class="err">Run stopped: ${_h(r.error!)}</p>');
  b.writeln('<div class="summary">');
  for (final key in ['passed', 'failed', 'flaky', 'error', 'notRun']) {
    b.writeln('<span class="pill">${s[key]} ${key == 'notRun' ? 'not run' : key}</span>');
  }
  b.writeln('</div>');
  for (final f in r.flows) {
    final open = f.status == FlowStatus.passed || f.status == FlowStatus.flaky ? '' : ' open';
    b
      ..writeln('<details class="flow ${f.status.name}"$open>')
      ..writeln(
        '<summary><span class="badge">${f.status == FlowStatus.notRun ? 'not run' : f.status.name}</span> '
        '<strong>${_h(f.name)}</strong> <span class="file">${_h(f.file)}</span> '
        '<span class="file">${(f.durationMs / 1000).toStringAsFixed(1)} s</span></summary>',
      )
      ..writeln('<div>');
    for (final a in f.attempts) {
      if (f.attempts.length > 1) b.writeln('<p>Attempt ${a.attempt}: ${_h(a.status)}</p>');
      b.writeln('<table><tr><th>Status</th><th>Step</th><th>What</th><th>Time</th></tr>');
      for (final step in a.steps) {
        b.writeln(
          '<tr><td class="s-${step.status.name}">${step.status.name}</td><td>${_h(step.id)}</td><td>${_h(step.label)}',
        );
        if (step.note != null) b.writeln('<div class="file">${_h(step.note!)}</div>');
        if (step.error != null) {
          b.writeln('<div class="err">${_h(step.error!.code)}: ${_h(step.error!.message)}</div>');
        }
        if (step.logTail.isNotEmpty) b.writeln('<pre>${_h(step.logTail.join('\n'))}</pre>');
        final c = step.comparison;
        if (c != null) _comparison(b, c);
        final shown = {?c?.baseline, ?c?.actual, ?c?.diff};
        final images = [
          for (final x in step.artifacts)
            if (x.toLowerCase().endsWith('.png') && !shown.contains(x)) x,
        ];
        final others = [
          for (final x in step.artifacts)
            if (!x.toLowerCase().endsWith('.png')) x,
        ];
        if (images.isNotEmpty) {
          b.writeln('<div class="shots">');
          for (final x in images) {
            b.writeln('<a href="${_h(x)}"><img src="${_h(x)}" alt="${_h(p.basename(x))}" loading="lazy"></a>');
          }
          b.writeln('</div>');
        }
        for (final x in others) {
          b.writeln('<div><a href="${_h(x)}">${_h(p.basename(x))}</a></div>');
        }
        b.writeln('</td><td class="num">${step.durationMs} ms</td></tr>');
      }
      b.writeln('</table>');
    }
    if (f.attempts.isEmpty) {
      if (f.status == FlowStatus.error && r.error != null) {
        // No step recorded the failure (e.g. session.reset() failed before
        // the flow's first attempt started), so the run error is the only
        // account of what happened; show it instead of a bare "Not run.".
        b.writeln('<p class="err">${_h(r.error!)}</p>');
      } else {
        b.writeln('<p class="file">Not run.</p>');
      }
    }
    b
      ..writeln('</div>')
      ..writeln('</details>');
  }
  b.writeln('</main></body></html>');
  return b.toString();
}

/// Writes `report.html` into [runDir] and returns its path.
String writeHtml(RunResult r, String runDir) {
  final file = File(p.join(runDir, 'report.html'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(renderHtml(r));
  return file.path;
}
