import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../driver/qa_driver.dart';

class SmokeStep {
  SmokeStep(this.name, this.run);
  final String name;
  final Future<void> Function(QaDriver driver) run;
}

class SmokeResult {
  SmokeResult(this.name, this.ok, this.duration, this.error);
  final String name;
  final bool ok;
  final Duration duration;
  final String? error;
}

class SmokeReport {
  SmokeReport(this.results);
  final List<SmokeResult> results;
  bool get passed => results.every((r) => r.ok);

  String toText() => [
    for (final r in results)
      '${r.ok ? 'PASS' : 'FAIL'}  ${r.name.padRight(40)} ${r.duration.inMilliseconds.toString().padLeft(6)} ms'
          '${r.error == null ? '' : '\n      ${r.error}'}',
    passed ? 'ALL PASSED' : 'FAILED',
  ].join('\n');
}

/// Runs steps in order, stops at the first failure and screenshots it.
class SmokeRunner {
  SmokeRunner(this.driver, {required this.outDir, void Function(String)? log}) : _log = log ?? ((_) {});

  final QaDriver driver;
  final String outDir;
  final void Function(String) _log;

  Future<SmokeReport> run(List<SmokeStep> steps) async {
    Directory(outDir).createSync(recursive: true);
    final logFile = File(p.join(outDir, 'smoke.log')).openWrite();
    final results = <SmokeResult>[];
    try {
      for (final step in steps) {
        final watch = Stopwatch()..start();
        try {
          await step.run(driver);
          results.add(SmokeResult(step.name, true, watch.elapsed, null));
          _report(logFile, results.last);
        } catch (e) {
          results.add(SmokeResult(step.name, false, watch.elapsed, e.toString()));
          _report(logFile, results.last);
          final safe = step.name.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-');
          try {
            await driver.screenshot(path: p.join(outDir, 'failure-$safe.png'));
          } catch (shotError) {
            logFile.writeln('failure screenshot failed: $shotError');
          }
          break;
        }
      }
    } finally {
      await logFile.close();
    }
    return SmokeReport(results);
  }

  void _report(IOSink log, SmokeResult r) {
    final line =
        '${r.ok ? 'PASS' : 'FAIL'} ${r.name} (${r.duration.inMilliseconds} ms)${r.error == null ? '' : ': ${r.error}'}';
    log.writeln(line);
    _log(line);
  }
}

/// The Stage 1 acceptance scenario against example/demo_app.
List<SmokeStep> demoAppSmokeSteps(String outDir) {
  Selector id(String v) => Selector(id: v);
  Selector text(String v) => Selector(text: v);
  Selector regex(String v, {int? index}) => Selector(textRegex: v, index: index);
  return [
    SmokeStep('wait for idle', (d) => d.waitForIdle()),
    SmokeStep('login screen visible', (d) => d.assertVisible(text('Welcome'))),
    SmokeStep('tap username', (d) => d.tap(id('username'))),
    SmokeStep('type username', (d) => d.enterText('alice')),
    SmokeStep('tap password', (d) => d.tap(id('password'))),
    SmokeStep('type wrong password', (d) => d.enterText('wrong')),
    SmokeStep('press enter', (d) => d.pressKey('enter')),
    SmokeStep('error shown', (d) => d.assertVisible(text('Wrong password'))),
    SmokeStep('set correct password', (d) => d.setText('secret', selector: id('password'))),
    SmokeStep('press enter again', (d) => d.pressKey('enter')),
    SmokeStep('list screen visible', (d) => d.assertVisible(text('Item 0'))),
    SmokeStep('list screenshot', (d) => d.screenshot(path: p.join(outDir, 'list.png'))),
    // 6000, not 2000: list tiles are 48-56px, so a 2000px scroll can never
    // reach an "Item 1xx" tile. 6000 lands on items roughly 107-125.
    SmokeStep('scroll list', (d) => d.scrollDirection(selector: id('item_list'), direction: 'down', amount: 6000)),
    SmokeStep('later item visible', (d) => d.assertVisible(regex('Item 1[0-9]{2}'))),
    SmokeStep('tap later item', (d) => d.tap(regex('Item 1[0-9]{2}', index: 0))),
    SmokeStep('snackbar visible', (d) => d.assertVisible(regex('Tapped Item 1[0-9]{2}'))),
    SmokeStep('go to dialog screen', (d) => d.tap(id('go_dialog'))),
    SmokeStep('open dialog', (d) => d.tap(id('open_dialog'))),
    SmokeStep('dialog visible', (d) => d.assertVisible(text('Enter a value'))),
    SmokeStep('type into dialog and confirm', (d) async {
      await d.enterText('hello');
      await d.tap(text('OK'));
      await d.assertVisible(text('hello'));
    }),
    SmokeStep('hover shows tooltip', (d) async {
      await d.hover(id('open_dialog'));
      // Restricted to type Text: the finder reports Tooltip.message as the
      // Tooltip node's own text too, so a plain text selector would match
      // the Tooltip node even without hovering. Requiring the Text widget
      // proves the tooltip overlay actually appeared.
      await d.assertVisible(Selector(text: 'Opens a dialog', type: 'Text'));
    }),
    SmokeStep('final screenshot', (d) => d.screenshot(path: p.join(outDir, 'final.png'))),
  ];
}
