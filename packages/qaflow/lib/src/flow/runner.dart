import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../device/device.dart';
import '../driver/qa_driver.dart';
import '../launch/launched_app.dart';
import '../screenshot/screenshot_comparison.dart';
import 'app_session.dart';
import 'events.dart';
import 'executor.dart';
import 'model.dart';
import 'parser.dart';
import 'variables.dart';

enum ScreenshotPolicy { failures, all, none }

class FlowRunOptions {
  const FlowRunOptions({
    required this.runDir,
    required this.runId,
    this.project = '',
    this.mode = '',
    this.env = const {},
    this.retries = 0,
    this.screenshots = ScreenshotPolicy.failures,
    this.preview = false,
    this.appRoot,
    this.baselines = BaselineMode.record,
    this.baselineKeySuffix,
  });
  final String runDir;
  final String runId;
  final String project;
  final String mode;

  /// `--env` values; they override flow header defaults.
  final Map<String, String> env;
  final int retries;
  final ScreenshotPolicy screenshots;

  /// Emit a [StepPreview] after each UI step.
  final bool preview;

  /// The folder that contains `.qa/`, where `assertScreenshot` keeps its
  /// baselines; null when the run has no project.
  final String? appRoot;
  final BaselineMode baselines;

  /// Appended to the device key, to keep separate baseline sets (e.g. CI).
  final String? baselineKeySuffix;
}

/// `yyyyMMdd-HHmmss` for a UTC time, e.g. `20260929-173624`.
String runIdFor(DateTime utc) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${utc.year}${two(utc.month)}${two(utc.day)}-${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
}

class _Failure implements Exception {
  _Failure(this.error);
  final StepError error;
}

/// A step inside runFlow or repeat failed; that step already recorded its
/// own artifacts.
class _NestedFailure extends _Failure {
  _NestedFailure(super.error);
}

/// Thrown between steps once [FlowRunner.stop] was called; unwinds the
/// current flow without running anything else.
class _StopRequested implements Exception {
  const _StopRequested();
}

class FlowRunner {
  FlowRunner({
    required this.session,
    required this.flows,
    required this.options,
    FlowParser? parser,
    this.executor = const CommandExecutor(),
  }) : parser = parser ?? FlowParser();

  final AppSession session;
  final List<Flow> flows;
  final FlowRunOptions options;
  final FlowParser parser;
  final CommandExecutor executor;

  /// Whether to emit a [StepPreview] after each UI step. Starts as
  /// [FlowRunOptions.preview]; a change applies to every preview after it.
  late bool preview = options.preview;

  static const int logTailLines = 50;
  static const int maxWhileIterations = 100;
  static const String stoppedMessage = 'stopped by the user';

  final StreamController<RunEvent> _events = StreamController<RunEvent>();
  final List<String> _logTail = [];
  bool _started = false;
  bool _stopRequested = false;

  /// A `setOrientation` step started since the last restore; set before it
  /// runs because it can rotate the device and still fail.
  bool _rotated = false;

  /// True until a UI command runs after the last start or reset.
  bool _fresh = false;
  String? _infraError;

  /// `step <id> (<label>): <description>` for the step that was in flight
  /// when an infrastructure error hit, set by the innermost `_runStep` that
  /// caught it. Reset per flow; `_runFlow` falls back to `_describe(e)`
  /// when an infra error has no step (e.g. from `session.reset()`).
  String? _infraStepDetail;
  late FlowInfo _flow;
  late String _flowDir;

  /// `screenshots/` in the flow's folder, or `screenshots/attempt-<n>/`
  /// after the first attempt, so each attempt keeps its own images.
  late String _screenshotDir;

  /// [baselineSlug] of the top-level flow in flight.
  late String _baselineSlug;
  double _viewWidth = 0;
  double _viewHeight = 0;
  String _platform = '';

  /// Names this device's baseline folder; set once the device is ready.
  String _deviceKey = '';

  /// Runs every flow (with retries) and closes the stream. Call once. The
  /// caller owns the session and stops it afterwards.
  Stream<RunEvent> run() {
    if (_started) throw StateError('a FlowRunner runs once');
    _started = true;
    unawaited(_run());
    return _events.stream;
  }

  /// Stops after the step in flight: no further step, flow or retry starts.
  void stop() => _stopRequested = true;

  bool _preparingDevice = false;

  /// True while waiting on the device to be ready.
  bool get preparingDevice => _preparingDevice;

  static String slugify(String s) {
    final slug = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'flow' : slug;
  }

  /// The folder name for [flowFile]'s screenshot baselines: its path under
  /// `<appRoot>/.qa/` without the extension, slugified
  /// (`.qa/flows/mobile/back.yaml` is `flows-mobile-back`), or its basename
  /// when it lives elsewhere. Unlike the output slug it ignores the flow's
  /// `name:` and the run's other flows, so it is stable across runs.
  static String baselineSlug(String flowFile, String? appRoot) {
    final file = p.normalize(p.absolute(flowFile));
    if (appRoot != null) {
      final qa = p.normalize(p.absolute(appRoot, '.qa'));
      if (p.isWithin(qa, file)) return slugify(p.withoutExtension(p.relative(file, from: qa)));
    }
    return slugify(p.basenameWithoutExtension(file));
  }

  void _emit(RunEvent e) => _events.add(e);

  Future<void> _run() async {
    final started = DateTime.now();
    final infos = _flowInfos();
    final counts = {for (final s in FlowStatus.values) s: 0};
    _emit(RunStarted(runId: options.runId, project: options.project, mode: options.mode, flows: infos));
    final logs = session.logs.listen((line) {
      _logTail.add(line);
      if (_logTail.length > logTailLines) _logTail.removeAt(0);
      _emit(AppLog(line: line));
    });
    try {
      try {
        if (_stopRequested) {
          _infraError ??= stoppedMessage;
        } else {
          _preparingDevice = true;
          final device = await session.prepareDevice(onBooting: (d) => _emit(DeviceBooting(device: d)));
          _preparingDevice = false;
          _deviceKey = device.baselineKey(suffix: options.baselineKeySuffix);
          _emit(DeviceReady(device: device));
          if (_stopRequested) {
            _infraError ??= stoppedMessage;
          } else {
            if (!session.isRunning) await session.start();
            _fresh = true;
          }
        }
      } catch (e) {
        _preparingDevice = false;
        _infraError = _stopRequested ? stoppedMessage : _describe(e);
      }
      for (var i = 0; i < flows.length; i++) {
        if (_stopRequested) _infraError ??= stoppedMessage;
        final FlowStatus status;
        if (_infraError != null) {
          status = FlowStatus.notRun;
          _emit(FlowFinished(flow: infos[i], status: status, duration: Duration.zero, attempts: 0));
        } else {
          status = await _runFlow(flows[i], infos[i], first: i == 0);
        }
        counts[status] = counts[status]! + 1;
      }
    } finally {
      await logs.cancel();
      _emit(RunFinished(duration: DateTime.now().difference(started), counts: counts, error: _infraError));
      await _events.close();
    }
  }

  List<FlowInfo> _flowInfos() {
    final used = <String>{};
    return [
      for (final f in flows)
        FlowInfo(name: f.name, file: f.file, tags: f.header.tags, slug: _unique(slugify(f.name), used)),
    ];
  }

  static String _unique(String slug, Set<String> used) {
    var candidate = slug;
    for (var n = 2; used.contains(candidate); n++) {
      candidate = '$slug-$n';
    }
    used.add(candidate);
    return candidate;
  }

  Future<FlowStatus> _runFlow(Flow flow, FlowInfo info, {required bool first}) async {
    final started = DateTime.now();
    _flow = info;
    _flowDir = p.join(options.runDir, 'flows', info.slug);
    _baselineSlug = baselineSlug(flow.file, options.appRoot);
    var status = FlowStatus.failed;
    var attempts = 0;
    _infraStepDetail = null;
    for (var attempt = 1; attempt <= options.retries + 1; attempt++) {
      if (attempt > 1 && _stopRequested) {
        _infraError ??= stoppedMessage;
        break;
      }
      attempts = attempt;
      _screenshotDir = attempt == 1
          ? p.join(_flowDir, 'screenshots')
          : p.join(_flowDir, 'screenshots', 'attempt-$attempt');
      try {
        if (!first || attempt > 1) {
          await session.reset();
          _fresh = true;
        }
        _emit(FlowStarted(flow: info, attempt: attempt));
        await _loadViewInfo();
        final passed = await _runAttempt(flow).whenComplete(_restoreOrientation);
        if (passed) {
          status = attempt > 1 ? FlowStatus.flaky : FlowStatus.passed;
          break;
        }
        status = FlowStatus.failed;
      } catch (e) {
        // A stop, or anything else that escapes the steps (reset, ping,
        // infrastructure), ends the run. A second stop in TestRun stops the
        // session under a step, which surfaces here as an infrastructure
        // error; the user asked for it, so the run still says "stopped".
        if (e is _StopRequested || _stopRequested) {
          _infraError ??= stoppedMessage;
        } else {
          // _infraStepDetail names the step that was in flight, if the error
          // came from one; otherwise (e.g. session.reset()) there is no step.
          _infraError = _infraStepDetail ?? _describe(e);
        }
        status = FlowStatus.error;
        break;
      }
    }
    _emit(FlowFinished(flow: info, status: status, duration: DateTime.now().difference(started), attempts: attempts));
    return status;
  }

  Future<void> _restoreOrientation() async {
    if (!_rotated) return;
    _rotated = false;
    try {
      if (session.isRunning) {
        await session.deviceController.setOrientation(ScreenOrientation.portrait, session.driver);
      } else {
        // stopApp or a crash left an Android device in the flow's rotation.
        await session.deviceController.resetOrientation();
      }
    } catch (e) {
      _emit(AppLog(line: '[qa] could not restore portrait orientation: ${_describe(e)}'));
    }
  }

  Future<void> _loadViewInfo() async {
    final pong = await session.driver.ping();
    final views = (pong.result?['views'] as List?) ?? const [];
    final view = views.isEmpty ? const <String, Object?>{} : (views.first as Map).cast<String, Object?>();
    _viewWidth = (view['width'] as num?)?.toDouble() ?? 0;
    _viewHeight = (view['height'] as num?)?.toDouble() ?? 0;
    _platform = pong.result?['platform'] as String? ?? '';
  }

  Future<bool> _runAttempt(Flow flow) async {
    final scope = VariableScope(flow.header.env).child(options.env);
    var phase = 0;
    try {
      final startOk = await _runList(flow.header.onFlowStart, 'start.', scope, flow.file);
      phase = 1;
      final bodyOk = startOk ? await _runList(flow.commands, '', scope, flow.file) : _skip(flow.commands, '');
      phase = 2;
      final completeOk = await _runList(flow.header.onFlowComplete, 'complete.', scope, flow.file);
      return startOk && bodyOk && completeOk;
    } on _StopRequested {
      if (phase < 1) _skip(flow.commands, '');
      if (phase < 2) _skip(flow.header.onFlowComplete, 'complete.');
      rethrow;
    }
  }

  Future<bool> _runList(List<Command> commands, String prefix, VariableScope scope, String flowFile) async {
    for (var i = 0; i < commands.length; i++) {
      if (_stopRequested) {
        _skip(commands.sublist(i), prefix, offset: i);
        throw const _StopRequested();
      }
      final bool ok;
      try {
        ok = await _runStep(commands[i], '$prefix${i + 1}', scope, flowFile);
      } on _StopRequested {
        _skip(commands.sublist(i + 1), prefix, offset: i + 1);
        rethrow;
      }
      if (!ok) {
        _skip(commands.sublist(i + 1), prefix, offset: i + 1);
        return false;
      }
    }
    return true;
  }

  bool _skip(List<Command> commands, String prefix, {int offset = 0}) {
    for (var i = 0; i < commands.length; i++) {
      final c = commands[i];
      _emit(
        StepFinished(
          flow: _flow,
          stepId: '$prefix${offset + i + 1}',
          label: c.title,
          command: c.name,
          status: StepStatus.skipped,
          duration: Duration.zero,
        ),
      );
    }
    return false;
  }

  Future<bool> _runStep(Command c, String id, VariableScope scope, String flowFile) async {
    _emit(StepStarted(flow: _flow, stepId: id, label: c.title, command: c.name));
    final watch = Stopwatch()..start();
    final artifacts = <String>[];
    try {
      final outcome = await _execute(c, id, scope, flowFile);
      artifacts.addAll(outcome.artifacts);
      // assertScreenshot already saved `<name>.actual.png`.
      if (options.screenshots == ScreenshotPolicy.all && _isUi(c) && c is! AssertScreenshot && session.isRunning) {
        artifacts.add(await _screenshot('step-$id'));
      }
      _finished(
        c,
        id,
        outcome.warn ? StepStatus.warned : StepStatus.passed,
        watch.elapsed,
        artifacts: artifacts,
        note: outcome.note,
        comparison: outcome.comparison,
      );
      await _preview(c, id);
      return true;
    } catch (e) {
      if (e is _StopRequested) {
        // A runFlow or repeat step whose children were cut short.
        _finished(c, id, StepStatus.skipped, watch.elapsed, note: 'stopped');
        rethrow;
      }
      if (_isInfra(e)) {
        // The connection may be gone; do not try to capture failure
        // artifacts. This step is the one that was in flight the first
        // time this branch runs; an outer runFlow/repeat step that also
        // unwinds through here (rethrow below) finds _infraStepDetail
        // already set and leaves it naming the inner step.
        _infraStepDetail ??= 'step $id (${c.title}): ${_describe(e)}';
        _finished(c, id, StepStatus.failed, watch.elapsed, error: _stepError(e), artifacts: artifacts);
        rethrow;
      }
      final error = _stepError(e);
      ScreenshotComparison? comparison;
      if (e is ScreenshotMismatch) {
        artifacts.addAll(e.artifacts.map(_relative));
        comparison = _relativeComparison(e.comparison);
      }
      if (c.optional) {
        _finished(c, id, StepStatus.warned, watch.elapsed, error: error, artifacts: artifacts, comparison: comparison);
        await _preview(c, id);
        return true;
      }
      final logTail = List<String>.of(_logTail);
      if (e is! _NestedFailure) {
        // A failed assertScreenshot already saved `<name>.actual.png`, which
        // is the failure screenshot.
        await _failureArtifacts(
          id,
          artifacts,
          screenshot: options.screenshots != ScreenshotPolicy.none && e is! ScreenshotMismatch,
        );
      }
      _finished(
        c,
        id,
        StepStatus.failed,
        watch.elapsed,
        error: error,
        artifacts: artifacts,
        logTail: logTail,
        comparison: comparison,
      );
      await _preview(c, id);
      return false;
    }
  }

  void _finished(
    Command c,
    String id,
    StepStatus status,
    Duration duration, {
    StepError? error,
    List<String> artifacts = const [],
    String? note,
    List<String> logTail = const [],
    ScreenshotComparison? comparison,
  }) {
    _emit(
      StepFinished(
        flow: _flow,
        stepId: id,
        label: c.title,
        command: c.name,
        status: status,
        duration: duration,
        error: error,
        artifacts: List.unmodifiable(artifacts),
        note: note,
        logTail: logTail,
        comparison: comparison,
      ),
    );
  }

  String _relative(String path) => p.relative(path, from: options.runDir);

  ScreenshotComparison _relativeComparison(ScreenshotComparison c) => ScreenshotComparison(
    name: c.name,
    baselinePath: c.baselinePath,
    deviceKey: c.deviceKey,
    outcome: c.outcome,
    threshold: c.threshold,
    mismatchPercent: c.mismatchPercent,
    actual: _relative(c.actual),
    baseline: c.baseline == null ? null : _relative(c.baseline!),
    diff: c.diff == null ? null : _relative(c.diff!),
  );

  /// Artifact and comparison paths in the outcome are relative to the run
  /// folder.
  Future<CommandOutcome> _execute(Command c, String id, VariableScope scope, String flowFile) async {
    switch (c) {
      case LaunchApp(:final clearState, :final stopApp):
        if (!session.isRunning) {
          await session.start();
          if (clearState) await session.reset(clearState: true);
        } else if (clearState) {
          await session.reset(clearState: true);
        } else if (_fresh) {
          return const CommandOutcome(note: 'app already fresh');
        } else if (!stopApp) {
          return const CommandOutcome(note: 'app already running');
        } else {
          await session.reset();
        }
        _fresh = true;
        await _loadViewInfo();
        return CommandOutcome.none;
      case StopApp():
        await session.stop();
        _fresh = false;
        return CommandOutcome.none;
      case ClearState():
        await session.reset(clearState: true);
        _fresh = true;
        await _loadViewInfo();
        return CommandOutcome.none;
      case RunFlow():
        return CommandOutcome(note: await _runFlowStep(c, id, scope, flowFile));
      case Repeat():
        return CommandOutcome(note: await _repeat(c, id, scope, flowFile));
      default:
        if (!session.isRunning) {
          throw QaException(QaErrorCode.notReady, 'the app is not running; add launchApp after stopApp');
        }
        _fresh = false;
        if (c is SetOrientation) _rotated = true;
        final outcome = await executor.execute(
          c,
          ExecutionContext(
            driver: session.driver,
            scope: scope,
            screenshotDir: _screenshotDir,
            viewWidth: _viewWidth,
            viewHeight: _viewHeight,
            device: session.deviceController,
            // The top-level flow's slug for subflow steps too, so a
            // baseline name only needs to be unique within one flow file.
            baselines: BaselineContext(
              appRoot: options.appRoot,
              deviceKey: _deviceKey,
              flowSlug: _baselineSlug,
              mode: options.baselines,
            ),
          ),
        );
        final comparison = outcome.comparison;
        return CommandOutcome(
          artifacts: [for (final f in outcome.artifacts) _relative(f)],
          note: outcome.note,
          warn: outcome.warn,
          comparison: comparison == null ? null : _relativeComparison(comparison),
        );
    }
  }

  Future<String?> _runFlowStep(RunFlow c, String id, VariableScope scope, String flowFile) async {
    if (c.when != null && !await _holds(c.when!, scope)) return 'condition not met';
    final env = {for (final e in c.env.entries) e.key: scope.substitute(e.value)};
    final bool ok;
    if (c.commands != null) {
      ok = await _runList(c.commands!, '$id.', scope.child(env), flowFile);
    } else {
      final sub = c.subflow ?? parser.parseFile(p.normalize(p.join(p.dirname(flowFile), scope.substitute(c.file!))));
      final subScope = VariableScope(sub.header.env, scope).child(options.env).child(env);
      final startOk = await _runList(sub.header.onFlowStart, '$id.start.', subScope, sub.file);
      final bodyOk = startOk ? await _runList(sub.commands, '$id.', subScope, sub.file) : _skip(sub.commands, '$id.');
      final completeOk = await _runList(sub.header.onFlowComplete, '$id.complete.', subScope, sub.file);
      ok = startOk && bodyOk && completeOk;
    }
    if (!ok) throw _NestedFailure(StepError('failed', 'a step inside "${c.title}" failed'));
    return null;
  }

  Future<String?> _repeat(Repeat c, String id, VariableScope scope, String flowFile) async {
    final limit = c.times ?? maxWhileIterations;
    var i = 0;
    while (i < limit) {
      if (c.whileCondition != null && !await _holds(c.whileCondition!, scope)) return '$i iteration(s)';
      i++;
      if (!await _runList(c.commands, '$id.$i.', scope, flowFile)) {
        throw _NestedFailure(StepError('failed', 'iteration $i of "${c.title}" failed'));
      }
    }
    if (c.times == null) {
      throw _Failure(StepError('repeat_limit', 'repeat limit reached after $maxWhileIterations iterations'));
    }
    return '$i iteration(s)';
  }

  Future<bool> _holds(Condition c, VariableScope scope) async {
    if (c.platform != null && c.platform!.toLowerCase() != _platform.toLowerCase()) return false;
    if (c.isTrue != null) {
      final value = scope.substitute(c.isTrue!).trim().toLowerCase();
      if (value != 'true' && value != 'false') {
        throw QaException(QaErrorCode.badRequest, 'condition "true" must be true or false, got "$value"');
      }
      if (value == 'false') return false;
    }
    if (c.visible != null || c.notVisible != null) {
      if (!session.isRunning) throw QaException(QaErrorCode.notReady, 'the app is not running');
      final d = session.driver;
      await d.waitForIdle();
      if (c.visible != null && !(await d.find(CommandExecutor.toSelector(c.visible!, scope))).any((n) => n.visible)) {
        return false;
      }
      if (c.notVisible != null &&
          (await d.find(CommandExecutor.toSelector(c.notVisible!, scope))).any((n) => n.visible)) {
        return false;
      }
    }
    return true;
  }

  Future<String> _screenshot(String name) async {
    final path = CommandExecutor.screenshotPath(_screenshotDir, name);
    await session.driver.screenshot(path: path);
    return _relative(path);
  }

  Future<void> _preview(Command c, String id) async {
    if (!preview || !_isUi(c) || !session.isRunning) return;
    try {
      _emit(StepPreview(flow: _flow, stepId: id, png: await session.driver.screenshotBytes()));
    } catch (_) {
      // A missing preview must not fail the step or the run.
    }
  }

  Future<void> _failureArtifacts(String id, List<String> artifacts, {required bool screenshot}) async {
    if (!session.isRunning) return;
    if (screenshot) {
      try {
        artifacts.add(await _screenshot('failure-$id'));
      } catch (_) {
        // Best effort: the failure itself is what the report needs.
      }
    }
    try {
      final nodes = await session.driver.elements();
      final file = File(p.join(_flowDir, 'elements-$id.json'));
      await file.parent.create(recursive: true);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert([for (final n in nodes) n.toJson()]));
      artifacts.add(p.relative(file.path, from: options.runDir));
    } catch (_) {
      // Best effort, as above.
    }
  }

  static bool _isUi(Command c) => c is! LaunchApp && c is! StopApp && c is! ClearState && c is! RunFlow && c is! Repeat;

  static bool _isInfra(Object e) =>
      e is LaunchException ||
      (e is QaException && e.details.containsKey('rpcCode')) ||
      (e is QaStepFailure && e.last.details.containsKey('rpcCode'));

  static String _describe(Object e) => switch (e) {
    LaunchException(:final message) => message,
    QaStepFailure(:final label, :final last) => '$label: ${last.message}',
    QaException(:final message) => message,
    _ => e.toString(),
  };

  static StepError _stepError(Object e) => switch (e) {
    _Failure(:final error) => error,
    QaStepFailure(:final last) => StepError(last.code.wire, last.message),
    QaException(:final code, :final message) => StepError(code.wire, message),
    UndefinedVariableException() || FlowParseException() => StepError(QaErrorCode.badRequest.wire, e.toString()),
    ScreenshotMismatch(:final message) => StepError('screenshot_mismatch', message),
    _ => StepError(QaErrorCode.internal.wire, e.toString()),
  };
}
