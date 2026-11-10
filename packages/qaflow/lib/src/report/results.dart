import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../device/device.dart';
import '../flow/events.dart';
import '../screenshot/screenshot_comparison.dart';

List<String> _strings(Object? list) => [for (final v in (list as List?) ?? const []) v as String];

class StepResult {
  const StepResult({
    required this.id,
    required this.label,
    required this.command,
    required this.status,
    required this.durationMs,
    this.error,
    this.note,
    this.artifacts = const [],
    this.logTail = const [],
    this.comparison,
  });

  factory StepResult.fromJson(Map<String, Object?> j) => StepResult(
    id: j['id'] as String,
    label: j['label'] as String,
    command: j['command'] as String,
    status: StepStatus.values.byName(j['status'] as String),
    durationMs: (j['durationMs'] as num).toInt(),
    error: j['error'] == null ? null : StepError.fromJson((j['error'] as Map).cast<String, Object?>()),
    note: j['note'] as String?,
    artifacts: _strings(j['artifacts']),
    logTail: _strings(j['logTail']),
    comparison: j['comparison'] == null
        ? null
        : ScreenshotComparison.fromJson((j['comparison'] as Map).cast<String, Object?>()),
  );

  final String id;
  final String label;
  final String command;
  final StepStatus status;
  final int durationMs;
  final StepError? error;
  final String? note;

  /// Relative to the run folder.
  final List<String> artifacts;
  final List<String> logTail;
  final ScreenshotComparison? comparison;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'command': command,
    'status': status.name,
    'durationMs': durationMs,
    if (error != null) 'error': error!.toJson(),
    if (note != null) 'note': note,
    'artifacts': artifacts,
    if (logTail.isNotEmpty) 'logTail': logTail,
    if (comparison != null) 'comparison': comparison!.toJson(),
  };
}

/// A dotted step id as sortable numbers (`2.10` is `[2, 10]`), or null
/// when a part is neither a number nor a hook. A hook part sorts around the
/// body at its level, as the runner runs it: `start` before every number,
/// `complete` after, so `start.1` < `1` < `2.start.1` < `2.1` < `complete.1`.
List<int>? stepIdParts(String id) {
  final out = <int>[];
  for (final part in id.split('.')) {
    final n = switch (part) {
      'start' => -1,
      'complete' => _completePart,
      _ => int.tryParse(part),
    };
    if (n == null || n < -1) return null;
    out.add(n);
  }
  return out;
}

/// Larger than any step number a flow can have.
const _completePart = 1 << 30;

/// Orders [stepIdParts] the way a flow runs its steps: `2` before `2.1`
/// before `2.10` before `3`, with hooks around the body.
int compareStepIdParts(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// [steps] in the order the flow lists them. Steps are recorded as they
/// finish, and a `runFlow` step (`2`) finishes after its children (`2.1`,
/// `2.2`), so this sorts by the dotted step id, numerically per part.
/// A list holding any id [stepIdParts] cannot read is returned as is.
List<StepResult> inRunOrder(List<StepResult> steps) {
  final keyed = [for (var i = 0; i < steps.length; i++) (i, stepIdParts(steps[i].id), steps[i])];
  if (keyed.any((k) => k.$2 == null)) return steps;
  keyed.sort((a, b) {
    final c = compareStepIdParts(a.$2!, b.$2!);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final k in keyed) k.$3];
}

class AttemptResult {
  const AttemptResult({required this.attempt, required this.status, required this.steps});

  factory AttemptResult.fromJson(Map<String, Object?> j) => AttemptResult(
    attempt: (j['attempt'] as num).toInt(),
    status: j['status'] as String,
    // Files written before the builder sorted its steps hold them in finish order.
    steps: inRunOrder([for (final s in j['steps'] as List) StepResult.fromJson((s as Map).cast<String, Object?>())]),
  );

  final int attempt;

  /// `passed`, `failed` or `error`.
  final String status;
  final List<StepResult> steps;

  Map<String, Object?> toJson() => {
    'attempt': attempt,
    'status': status,
    'steps': [for (final s in steps) s.toJson()],
  };
}

class FlowResult {
  const FlowResult({
    required this.name,
    required this.file,
    required this.slug,
    required this.tags,
    required this.status,
    required this.durationMs,
    required this.attempts,
  });

  factory FlowResult.fromJson(Map<String, Object?> j) => FlowResult(
    name: j['name'] as String,
    file: j['file'] as String,
    slug: j['slug'] as String,
    tags: _strings(j['tags']),
    status: FlowStatus.values.byName(j['status'] as String),
    durationMs: (j['durationMs'] as num).toInt(),
    attempts: [for (final a in j['attempts'] as List) AttemptResult.fromJson((a as Map).cast<String, Object?>())],
  );

  final String name;
  final String file;
  final String slug;
  final List<String> tags;
  final FlowStatus status;
  final int durationMs;
  final List<AttemptResult> attempts;

  Map<String, Object?> toJson() => {
    'name': name,
    'file': file,
    'slug': slug,
    'tags': tags,
    'status': status.name,
    'durationMs': durationMs,
    'attempts': [for (final a in attempts) a.toJson()],
  };
}

class RunResult {
  const RunResult({
    required this.runId,
    required this.project,
    required this.mode,
    required this.startedAt,
    required this.durationMs,
    required this.flows,
    this.error,
    this.device,
  });

  factory RunResult.fromJson(Map<String, Object?> j) {
    final version = j['schemaVersion'];
    if (version != schemaVersion) throw FormatException('unsupported results schemaVersion $version');
    return RunResult(
      runId: j['runId'] as String,
      project: j['project'] as String,
      mode: j['mode'] as String,
      startedAt: DateTime.parse(j['startedAt'] as String),
      durationMs: (j['durationMs'] as num).toInt(),
      error: j['error'] as String?,
      device: j['device'] == null ? null : DeviceInfo.fromJson((j['device'] as Map).cast<String, Object?>()),
      flows: [for (final f in j['flows'] as List) FlowResult.fromJson((f as Map).cast<String, Object?>())],
    );
  }

  static const int schemaVersion = 1;

  final String runId;
  final String project;
  final String mode;
  final DateTime startedAt;
  final int durationMs;

  /// Why the run stopped early, if it did.
  final String? error;
  final List<FlowResult> flows;

  /// Where the run ran; null in results written before devices were recorded.
  final DeviceInfo? device;

  Map<String, int> get summary {
    int count(FlowStatus s) => flows.where((f) => f.status == s).length;
    return {
      'total': flows.length,
      'passed': count(FlowStatus.passed),
      'failed': count(FlowStatus.failed),
      'flaky': count(FlowStatus.flaky),
      'error': count(FlowStatus.error),
      'notRun': count(FlowStatus.notRun),
    };
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'runId': runId,
    'project': project,
    'mode': mode,
    if (device != null) 'device': device!.toJson(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'durationMs': durationMs,
    'summary': summary,
    if (error != null) 'error': error,
    'flows': [for (final f in flows) f.toJson()],
  };
}

/// Folds a run's events into a [RunResult].
class RunResultBuilder {
  String _runId = '';
  String _project = '';
  String _mode = '';
  DateTime? _startedAt;
  int _durationMs = 0;
  String? _error;
  DeviceInfo? _device;
  final List<String> _order = [];
  final Map<String, _FlowAcc> _flows = {};

  void add(RunEvent e) {
    switch (e) {
      case RunStarted():
        _runId = e.runId;
        _project = e.project;
        _mode = e.mode;
        _startedAt = e.time;
        for (final f in e.flows) {
          _acc(f);
        }
      case FlowStarted():
        _acc(e.flow).attempts.add(_AttemptAcc(e.attempt));
      case StepFinished():
        final acc = _acc(e.flow);
        if (acc.attempts.isEmpty) acc.attempts.add(_AttemptAcc(1));
        acc.attempts.last.steps.add(
          StepResult(
            id: e.stepId,
            label: e.label,
            command: e.command,
            status: e.status,
            durationMs: e.duration.inMilliseconds,
            error: e.error,
            note: e.note,
            artifacts: e.artifacts,
            logTail: e.logTail,
            comparison: e.comparison,
          ),
        );
      case FlowFinished():
        final acc = _acc(e.flow);
        acc.status = e.status;
        acc.durationMs = e.duration.inMilliseconds;
      case RunFinished():
        _durationMs = e.duration.inMilliseconds;
        _error = e.error;
      case DeviceReady():
        _device = e.device;
      case StepStarted() || AppLog() || StepPreview() || DeviceBooting():
        break;
    }
  }

  _FlowAcc _acc(FlowInfo f) => _flows.putIfAbsent(f.slug, () {
    _order.add(f.slug);
    return _FlowAcc(f);
  });

  RunResult build() => RunResult(
    runId: _runId,
    project: _project,
    mode: _mode,
    startedAt: (_startedAt ?? DateTime.now()).toUtc(),
    durationMs: _durationMs,
    error: _error,
    device: _device,
    flows: [for (final slug in _order) _flows[slug]!.build()],
  );
}

class _AttemptAcc {
  _AttemptAcc(this.attempt);
  final int attempt;
  final List<StepResult> steps = [];
}

class _FlowAcc {
  _FlowAcc(this.info);
  final FlowInfo info;
  final List<_AttemptAcc> attempts = [];
  FlowStatus status = FlowStatus.notRun;
  int durationMs = 0;

  FlowResult build() {
    final lastStatus = switch (status) {
      FlowStatus.passed || FlowStatus.flaky => 'passed',
      FlowStatus.error => 'error',
      _ => 'failed',
    };
    return FlowResult(
      name: info.name,
      file: info.file,
      slug: info.slug,
      tags: info.tags,
      status: status,
      durationMs: durationMs,
      attempts: [
        for (var i = 0; i < attempts.length; i++)
          AttemptResult(
            attempt: attempts[i].attempt,
            status: i == attempts.length - 1 ? lastStatus : 'failed',
            steps: List.unmodifiable(inRunOrder(attempts[i].steps)),
          ),
      ],
    );
  }
}

/// Writes `results.json` into [runDir] and returns its path.
String writeResultsJson(RunResult result, String runDir) {
  final file = File(p.join(runDir, 'results.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.toJson()));
  return file.path;
}
