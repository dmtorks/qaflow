import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../device/device.dart';
import '../driver/qa_driver.dart';
import '../screenshot/baseline_store.dart';
import '../screenshot/image_compare.dart';
import '../screenshot/screenshot_comparison.dart';
import 'model.dart';
import 'variables.dart';

class ExecutionContext {
  ExecutionContext({
    required this.driver,
    required this.scope,
    required this.screenshotDir,
    required this.viewWidth,
    required this.viewHeight,
    this.device = const UnsupportedDeviceController(DevicePlatform.macos),
    this.baselines,
  });
  final QaDriver driver;
  final VariableScope scope;
  final String screenshotDir;
  final double viewWidth;
  final double viewHeight;

  /// Rotation and deep links; unsupported on desktop.
  final DeviceController device;

  /// Where `assertScreenshot` keeps baselines; null without a project.
  final BaselineContext? baselines;
}

class BaselineContext {
  const BaselineContext({
    required this.appRoot,
    required this.deviceKey,
    required this.flowSlug,
    this.mode = BaselineMode.record,
  });
  final String? appRoot;
  final String deviceKey;
  final String flowSlug;
  final BaselineMode mode;
}

/// What a command produced besides side effects on the app.
class CommandOutcome {
  const CommandOutcome({this.artifacts = const [], this.note, this.warn = false, this.comparison});
  static const none = CommandOutcome();

  /// Absolute paths of files written.
  final List<String> artifacts;
  final String? note;
  final bool warn;
  final ScreenshotComparison? comparison;
}

class ScreenshotMismatch implements Exception {
  const ScreenshotMismatch(this.message, this.comparison, this.artifacts);
  final String message;
  final ScreenshotComparison comparison;
  final List<String> artifacts;

  @override
  String toString() => message;
}

/// Runs one UI command. App lifecycle (`launchApp`, `stopApp`,
/// `clearState`) and composition (`runFlow`, `repeat`) belong to the runner.
class CommandExecutor {
  const CommandExecutor();

  /// `scroll` moves the main scrollable by this percent of its visible extent.
  static const int scrollPercent = 70;

  /// `scrollUntilVisible` moves this fraction of the visible extent per step.
  static const double scrollStepFraction = 0.5;

  /// Maestro's swipe directions, as start and end points in percent.
  static const Map<Direction, (PointSpec, PointSpec)> _swipes = {
    Direction.left: (
      PointSpec(90, 50, xPercent: true, yPercent: true),
      PointSpec(10, 50, xPercent: true, yPercent: true),
    ),
    Direction.right: (
      PointSpec(10, 50, xPercent: true, yPercent: true),
      PointSpec(90, 50, xPercent: true, yPercent: true),
    ),
    Direction.down: (
      PointSpec(50, 20, xPercent: true, yPercent: true),
      PointSpec(50, 90, xPercent: true, yPercent: true),
    ),
    Direction.up: (
      PointSpec(50, 50, xPercent: true, yPercent: true),
      PointSpec(50, 10, xPercent: true, yPercent: true),
    ),
  };

  Future<CommandOutcome> execute(Command command, ExecutionContext ctx) async {
    final d = ctx.driver;
    final scope = ctx.scope;
    switch (command) {
      case Tap(:final kind, :final selector, :final point):
        if (selector != null) {
          final s = toSelector(selector, scope);
          switch (kind) {
            case TapKind.tap:
              await d.tap(s);
            case TapKind.doubleTap:
              await d.doubleTap(s);
            case TapKind.longPress:
              await d.longPress(s);
          }
        } else {
          final at = point!.resolve(left: 0, top: 0, width: ctx.viewWidth, height: ctx.viewHeight);
          await d.waitForIdle();
          switch (kind) {
            case TapKind.tap:
              await d.tapAt(at.x, at.y);
            case TapKind.doubleTap:
              await d.tapAt(at.x, at.y, count: 2);
            case TapKind.longPress:
              await d.longPressAt(at.x, at.y);
          }
        }
      case Hover(:final selector):
        await d.hover(toSelector(selector, scope));
      case InputText(:final text):
        await d.enterText(scope.substitute(text));
      case EraseText(:final count):
        await d.eraseText(count);
      case SetText(:final selector, :final text):
        await d.setText(scope.substitute(text), selector: toSelector(selector, scope));
      case PressKey(:final key):
        await d.pressKey(scope.substitute(key));
      case AssertVisible(:final selector):
        await d.assertVisible(toSelector(selector, scope));
      case AssertNotVisible(:final selector):
        await d.assertNotVisible(toSelector(selector, scope));
      case ExtendedWaitUntil(:final visible, :final notVisible, :final timeoutMs):
        final timeout = Duration(milliseconds: timeoutMs);
        if (visible != null) {
          await d.assertVisible(toSelector(visible, scope), timeout: timeout);
        } else {
          await d.assertNotVisible(toSelector(notVisible!, scope), timeout: timeout);
        }
      case WaitForAnimationToEnd(:final timeoutMs):
        await d.waitForIdle(timeout: Duration(milliseconds: timeoutMs));
      case Scroll():
        await d.waitForIdle();
        final area = await mainScrollable(d, null, scope);
        await d.scrollAt(area.centerX, area.centerY, dy: area.height * scrollPercent / 100);
      case ScrollUntilVisible():
        await _scrollUntilVisible(command, ctx);
      case Swipe():
        await _swipe(command, ctx);
      case TakeScreenshot(:final fileName):
        final path = screenshotPath(ctx.screenshotDir, scope.substitute(fileName));
        await d.screenshot(path: path);
        return CommandOutcome(artifacts: [path]);
      case Back():
        await d.back();
      case HideKeyboard():
        await d.hideKeyboard();
      case SetOrientation(:final orientation):
        await d.waitForIdle();
        await ctx.device.setOrientation(orientation, d);
        await d.waitForIdle();
      case OpenLink(:final link):
        await ctx.device.openLink(Uri.parse(scope.substitute(link)));
        // A link another app handles leaves this one in the background; the
        // next step that needs a frame reports that.
        try {
          await d.waitForIdle();
        } on QaException catch (e) {
          if (e.code != QaErrorCode.notReady) rethrow;
        }
      case AssertScreenshot():
        return _assertScreenshot(command, ctx);
      case LaunchApp() || StopApp() || ClearState() || RunFlow() || Repeat():
        throw StateError('${command.name} is run by the flow runner, not the executor');
    }
    return CommandOutcome.none;
  }

  Future<CommandOutcome> _assertScreenshot(AssertScreenshot c, ExecutionContext ctx) async {
    final b = ctx.baselines;
    final root = b?.appRoot;
    if (b == null || root == null) {
      throw QaException(
        QaErrorCode.badRequest,
        'assertScreenshot needs a project (pass --config or --project) to know where baselines live',
      );
    }
    final name = ctx.scope.substitute(c.screenshotName);
    final problem = BaselineStore.nameProblem(name);
    if (problem != null) throw QaException(QaErrorCode.badRequest, problem);

    final d = ctx.driver;
    final capture = await d.untilReady('assertScreenshot $name', d.screenshotCapture);
    final ignore = <({double x, double y, double width, double height})>[];
    for (final s in c.ignore) {
      for (final n in await d.find(toSelector(s, ctx.scope))) {
        final r = n.visibleRect;
        if (r != null) ignore.add((x: r.x, y: r.y, width: r.width, height: r.height));
      }
    }

    final store = BaselineStore(root);
    final baselinePath = store.pathFor(deviceKey: b.deviceKey, flowSlug: b.flowSlug, name: name);
    final relBaseline = p.relative(baselinePath, from: root);
    final actualPath = p.join(ctx.screenshotDir, '$name.actual.png');
    File(actualPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(capture.png);
    ScreenshotComparison record(ComparisonOutcome outcome, {double? percent, String? baseline, String? diff}) =>
        ScreenshotComparison(
          name: name,
          baselinePath: relBaseline,
          deviceKey: b.deviceKey,
          outcome: outcome,
          mismatchPercent: percent,
          threshold: c.threshold,
          actual: actualPath,
          baseline: baseline,
          diff: diff,
        );

    final existing = store.read(baselinePath);
    if (b.mode == BaselineMode.update || (existing == null && b.mode == BaselineMode.record)) {
      store.write(baselinePath, capture.png);
      final updated = b.mode == BaselineMode.update;
      return CommandOutcome(
        artifacts: [actualPath],
        note: updated ? 'baseline updated' : 'baseline recorded',
        warn: !updated,
        comparison: record(updated ? ComparisonOutcome.updated : ComparisonOutcome.recorded),
      );
    }
    if (existing == null) {
      throw ScreenshotMismatch(
        'no baseline for "$name" on ${b.deviceKey} (run with --baselines record or update)',
        record(ComparisonOutcome.failed),
        [actualPath],
      );
    }

    final baselineCopy = p.join(ctx.screenshotDir, '$name.baseline.png');
    File(baselineCopy).writeAsBytesSync(existing);
    final compared = await _compareOffThread(capture.png, existing, ignore, capture.devicePixelRatio, c.threshold);
    if (compared == null) throw QaException(QaErrorCode.badRequest, 'baseline $relBaseline is not a PNG');
    final result = ComparisonResult(
      passed: compared.passed,
      mismatchPercent: compared.mismatchPercent,
      sizeMismatch: compared.sizeMismatch,
    );
    if (result.passed) {
      return CommandOutcome(
        artifacts: [actualPath, baselineCopy],
        comparison: record(ComparisonOutcome.passed, percent: result.mismatchPercent, baseline: baselineCopy),
      );
    }
    String? diffPath;
    if (compared.diffPng case final diff?) {
      diffPath = p.join(ctx.screenshotDir, '$name.diff.png');
      File(diffPath).writeAsBytesSync(diff);
    }
    throw ScreenshotMismatch(
      result.describe(c.threshold),
      record(
        ComparisonOutcome.failed,
        percent: result.sizeMismatch == null ? result.mismatchPercent : null,
        baseline: baselineCopy,
        diff: diffPath,
      ),
      [actualPath, baselineCopy, ?diffPath],
    );
  }

  /// Decodes, compares and encodes the diff on another isolate, since a
  /// full-screen image takes long enough to stall QAFlow Studio's UI. Null when
  /// [baselinePng] is not a PNG.
  static Future<({bool passed, double mismatchPercent, String? sizeMismatch, Uint8List? diffPng})?> _compareOffThread(
    Uint8List actualPng,
    Uint8List baselinePng,
    List<({double x, double y, double width, double height})> ignore,
    double devicePixelRatio,
    double threshold,
  ) => Isolate.run(() {
    final actual = img.decodePng(actualPng)!;
    final baseline = img.decodePng(baselinePng);
    if (baseline == null) return null;
    final result = compareImages(
      actual,
      baseline,
      ignore: pixelRects(ignore, devicePixelRatio, actual.width, actual.height),
      thresholdPercent: threshold,
    );
    final diff = result.passed ? null : result.diff;
    return (
      passed: result.passed,
      mismatchPercent: result.mismatchPercent,
      sizeMismatch: result.sizeMismatch,
      diffPng: diff == null ? null : img.encodePng(diff),
    );
  });

  /// YAML `text` matches literally or as a full regular expression; a value
  /// that is not a valid Dart regular expression matches literally only.
  static Selector toSelector(FlowSelector s, VariableScope scope) {
    String? literal;
    String? regex;
    final text = s.text == null ? null : scope.substitute(s.text!);
    if (text != null) {
      try {
        RegExp(text);
        regex = '(?:$text)|(?:${RegExp.escape(text)})';
      } on FormatException {
        literal = text;
      }
    }
    return Selector(
      text: literal,
      textRegex: regex,
      id: s.id == null ? null : scope.substitute(s.id!),
      type: s.type,
      index: s.index,
      enabled: s.enabled,
      within: s.childOf == null ? null : toSelector(s.childOf!, scope),
    );
  }

  /// The scroll view a step names, or the visible `Scrollable` with the
  /// largest visible area.
  static Future<QaRect> mainScrollable(QaDriver d, FlowSelector? named, VariableScope scope) async {
    if (named != null) {
      final node = await d.assertVisible(toSelector(named, scope));
      return node.visibleRect ?? node.rect!;
    }
    QaRect? best;
    for (final n in await d.elements()) {
      final r = n.visibleRect;
      if (n.type != 'Scrollable' || r == null) continue;
      if (best == null || r.width * r.height > best.width * best.height) best = r;
    }
    return best ?? (throw QaException(QaErrorCode.notFound, 'no visible scrollable on screen'));
  }

  /// A PNG path for [name] inside [dir]; unsafe characters become `_`.
  static String screenshotPath(String dir, String name) {
    final base = name.toLowerCase().endsWith('.png') ? name.substring(0, name.length - 4) : name;
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._/-]+'), '_');
    final full = p.normalize(p.join(dir, '$safe.png'));
    if (!p.isWithin(p.normalize(dir), full)) {
      throw QaException(QaErrorCode.badRequest, 'screenshot path must stay inside the flow folder: $name');
    }
    return full;
  }

  Future<void> _scrollUntilVisible(ScrollUntilVisible c, ExecutionContext ctx) async {
    final d = ctx.driver;
    final target = toSelector(c.element, ctx.scope);
    final deadline = DateTime.now().add(Duration(milliseconds: c.timeoutMs));
    await d.waitForIdle();
    // Resolved once, before the loop, not on every iteration (spec 7.4:
    // "settles once"). A named scrollable goes through assertVisible,
    // whose retry loop settles on every attempt, so calling this per
    // iteration re-settled every scroll. The default largest-visible-area
    // form only reads elements() with no settle of its own, so it did not
    // cause that bug, but it is resolved once here too: a Scrollable's
    // screen rect is fixed by layout and does not move as its own content
    // is scrolled, so nothing on screen makes a different node become "the
    // main scrollable" partway through one scrollUntilVisible step.
    final area = await mainScrollable(d, c.scrollable, ctx.scope);
    while (true) {
      final match = _visibleEnough(await d.find(target), c.visibilityPercentage);
      if (match != null) {
        if (c.centerElement) await _center(match, area, c, ctx);
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw QaException(
          QaErrorCode.notFound,
          '${c.element} not visible after scrolling ${c.direction.name} for ${c.timeoutMs} ms',
        );
      }
      final (dx, dy) = _delta(c.direction, area, scrollStepFraction);
      // The agent waits a frame after each scroll chunk, so the next find
      // sees the rebuilt list; settling here would cost the stable-tier wait
      // on screens with endless animations.
      await d.scrollAt(area.centerX, area.centerY, dx: dx, dy: dy);
    }
  }

  static QaNode? _visibleEnough(List<QaNode> nodes, int percent) {
    for (final n in nodes) {
      final rect = n.rect;
      final visible = n.visibleRect;
      if (!n.visible || rect == null || visible == null) continue;
      final full = rect.width * rect.height;
      if (full <= 0) continue;
      if (visible.width * visible.height / full * 100 >= percent - 0.01) return n;
    }
    return null;
  }

  static (double, double) _delta(Direction direction, QaRect area, double fraction) => switch (direction) {
    Direction.down => (0.0, area.height * fraction),
    Direction.up => (0.0, -area.height * fraction),
    Direction.right => (area.width * fraction, 0.0),
    Direction.left => (-area.width * fraction, 0.0),
  };

  Future<void> _center(QaNode node, QaRect area, ScrollUntilVisible c, ExecutionContext ctx) async {
    final v = node.visibleRect!;
    final vertical = c.direction == Direction.up || c.direction == Direction.down;
    final offset = vertical ? v.centerY - area.centerY : v.centerX - area.centerX;
    if (offset.abs() < 1) return;
    await ctx.driver.scrollAt(area.centerX, area.centerY, dx: vertical ? 0 : offset, dy: vertical ? offset : 0);
  }

  Future<void> _swipe(Swipe c, ExecutionContext ctx) async {
    final d = ctx.driver;
    await d.waitForIdle();
    var box = (left: 0.0, top: 0.0, width: ctx.viewWidth, height: ctx.viewHeight);
    if (c.from != null) {
      final node = await d.assertVisible(toSelector(c.from!, ctx.scope));
      final r = node.visibleRect ?? node.rect!;
      box = (left: r.x, top: r.y, width: r.width, height: r.height);
    }
    final (startSpec, endSpec) = c.direction != null ? _swipes[c.direction!]! : (c.start!, c.end!);
    final start = startSpec.resolve(left: box.left, top: box.top, width: box.width, height: box.height);
    final end = endSpec.resolve(left: box.left, top: box.top, width: box.width, height: box.height);
    await d.dragAt(start.x, start.y, dx: end.x - start.x, dy: end.y - start.y, durationMs: c.durationMs);
  }
}
