import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../flow/app_session.dart';
import '../flow/events.dart';
import '../flow/model.dart';
import '../flow/parser.dart';
import '../flow/runner.dart';
import '../report/html_reporter.dart';
import '../report/junit_reporter.dart';
import '../report/results.dart';
import '../screenshot/screenshot_comparison.dart';
import '../session/qa_session.dart';

typedef SessionFactory =
    Future<AppSession> Function(ProjectConfig config, String runDir, void Function(String message) log);

class TestRunRequest {
  const TestRunRequest({
    required this.config,
    required this.flows,
    required this.outDir,
    this.parser,
    this.env = const {},
    this.retries = 0,
    this.screenshots = ScreenshotPolicy.failures,
    this.preview = false,
    this.appRoot,
    this.baselines = BaselineMode.record,
    this.baselineKeySuffix,
    this.log,
    this.hostToken,
  });

  final ProjectConfig config;
  final List<Flow> flows;

  /// Parent of the run folder; created if missing.
  final String outDir;

  /// The parser that parsed [flows]; reusing it shares its subflow cache.
  final FlowParser? parser;
  final Map<String, String> env;
  final int retries;
  final ScreenshotPolicy screenshots;
  final bool preview;

  /// The folder that contains `.qa/`; `assertScreenshot` keeps its baselines
  /// there. Null when the run has no project.
  final String? appRoot;
  final BaselineMode baselines;

  /// Appended to the device key; null falls back to `QA_BASELINE_KEY_SUFFIX`.
  final String? baselineKeySuffix;

  /// Session and launch messages, including `[app]` and `[vm]` lines.
  final void Function(String message)? log;

  /// The token for [ProjectConfig.host]; null reads `QA_HOST_TOKEN`.
  final String? hostToken;
}

class TestRunOutcome {
  const TestRunOutcome({
    required this.result,
    required this.resultsPath,
    required this.junitPath,
    required this.htmlPath,
    required this.isSuccess,
  });

  final RunResult result;
  final String resultsPath;
  final String junitPath;
  final String htmlPath;

  /// Every flow passed (flaky counts as passed) and the run was not cut short.
  final bool isSuccess;
}

/// One run of flows against one app: creates the run folder, starts the
/// session, runs the flows, stops the session and writes `results.json`,
/// `junit.xml` and `report.html`. `qa test` and QAFlow Studio both run flows
/// through this.
class TestRun {
  TestRun._(this.runId, this.runDir, this._session, this._runner);

  final String runId;
  final String runDir;
  final AppSession _session;
  final FlowRunner _runner;
  final StreamController<RunEvent> _events = StreamController<RunEvent>();
  final Completer<TestRunOutcome> _done = Completer<TestRunOutcome>();
  int _stops = 0;

  /// Creates the session first and the run folder only once that worked, so
  /// a setup failure (no Flutter, an invalid config) leaves no empty folder.
  /// [environment] defaults to `Platform.environment`.
  static Future<TestRun> start(
    TestRunRequest request, {
    SessionFactory? createSession,
    Map<String, String>? environment,
  }) async {
    final outDir = p.normalize(p.absolute(request.outDir));
    // The name is chosen here, before the session (and so the run) exists;
    // two runs started at the same moment could still race on this folder name.
    var runId = runIdFor(DateTime.now().toUtc());
    var runDir = p.join(outDir, runId);
    for (var n = 2; Directory(runDir).existsSync(); n++) {
      runDir = p.join(outDir, '$runId-$n');
    }
    runId = p.basename(runDir);
    final session = await (createSession ?? _qaSessionFactory(request.hostToken))(
      request.config,
      runDir,
      request.log ?? (_) {},
    );
    Directory(runDir).createSync(recursive: true);
    final runner = FlowRunner(
      session: session,
      flows: request.flows,
      parser: request.parser,
      options: FlowRunOptions(
        runDir: runDir,
        runId: runId,
        project: request.config.name,
        mode: request.config.mode.name,
        env: request.env,
        retries: request.retries,
        screenshots: request.screenshots,
        preview: request.preview,
        appRoot: request.appRoot,
        baselines: request.baselines,
        baselineKeySuffix: request.baselineKeySuffix ?? (environment ?? Platform.environment)['QA_BASELINE_KEY_SUFFIX'],
      ),
    );
    final run = TestRun._(runId, runDir, session, runner);
    unawaited(run._pump());
    return run;
  }

  static SessionFactory _qaSessionFactory(String? hostToken) =>
      (config, runDir, log) => QaSession.create(config, screenshotDirectory: runDir, log: log, hostToken: hostToken);

  /// Every event once; buffered until listened to. Listen once.
  Stream<RunEvent> get events => _events.stream;

  Future<TestRunOutcome> get done => _done.future;

  bool get preview => _runner.preview;
  set preview(bool value) => _runner.preview = value;

  /// First call: stop after the step in flight, or at once while the device
  /// is still booting. Second call: also stop the
  /// session, which ends the app under test and the step with it.
  void stop() {
    _stops++;
    final booting = _runner.preparingDevice;
    _runner.stop();
    if (_stops == 2 || (_stops == 1 && booting)) unawaited(_session.stop().catchError((Object _) {}));
  }

  Future<void> _pump() async {
    final results = RunResultBuilder();
    var success = false;
    try {
      try {
        await for (final e in _runner.run()) {
          results.add(e);
          if (e is RunFinished) success = e.isSuccess;
          _events.add(e);
        }
      } finally {
        await _session.stop();
      }
      final result = results.build();
      _done.complete(
        TestRunOutcome(
          result: result,
          resultsPath: writeResultsJson(result, runDir),
          junitPath: writeJunit(result, runDir),
          htmlPath: writeHtml(result, runDir),
          isSuccess: success,
        ),
      );
    } catch (e, st) {
      _done.completeError(e, st);
    } finally {
      // Not awaited: with no listener, close() would never complete.
      unawaited(_events.close());
    }
  }
}
