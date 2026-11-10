import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart' hide Command;
import 'package:qaflow_protocol/qaflow_protocol.dart';

/// Stops what the running command started; set while there is something
/// to stop. SIGINT and SIGTERM run it before qa exits.
Future<void> Function()? _stopActive;

/// [stop], run at most once however many times the result is called.
Future<void> Function() _once(Future<void> Function() stop) {
  Future<void>? stopping;
  return () => stopping ??= stop();
}

Future<void> main(List<String> argv) async {
  exitOnTermination(() async => _stopActive?.call());
  final runner = CommandRunner<int>('qa', 'Flutter desktop QA command line')
    ..addCommand(PingCommand())
    ..addCommand(SmokeCommand())
    ..addCommand(ValidateCommand())
    ..addCommand(TestCommand())
    ..addCommand(HostCommand());
  try {
    exit(await runner.run(argv) ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on ProjectFileException catch (e) {
    stderr.writeln('${p.relative(e.file)}:${e.line}:${e.column}: ${e.message}');
    exit(1);
  } on LaunchException catch (e) {
    stderr.writeln('qa: launch failed: ${e.message}');
    exit(1);
  } on RemoteHostException catch (e) {
    stderr.writeln('qa: ${e.message}');
    exit(1);
  } on QaStepFailure catch (e) {
    stderr.writeln('qa: step failed: ${e.label}: ${e.last.code.wire}: ${e.last.message}');
    exit(1);
  } on QaException catch (e) {
    stderr.writeln('qa: agent error: ${e.message}');
    exit(1);
  } on ArgumentError catch (e) {
    stderr.writeln('qa: invalid argument: ${e.message}');
    exit(1);
  }
}

/// `--config` when given, else `./.qa/project.yaml` when it exists.
String? projectFilePath(String? explicit) => explicit ?? ProjectFile.findIn(Directory.current.path);

mixin ProjectOptions on Command<int> {
  void addProjectOptions() {
    argParser
      ..addOption('config', help: 'Project file (default: .qa/project.yaml in the current folder, when it exists).')
      ..addOption('project', help: 'Path to the Flutter project (source launch).')
      ..addOption('binary', help: 'Path to a prebuilt debug/profile binary or .app bundle.')
      ..addOption('mode', allowed: ['debug', 'profile'], help: 'Build mode (default: the project file, else debug).')
      ..addOption(
        'device',
        help: 'macos, windows, linux, flutter-tester, ios:<simulator> or android:<AVD or serial> (default: host).',
      )
      ..addOption('entrypoint', help: 'Entrypoint that installs the agent (default: lib/main_qa.dart).')
      ..addOption('flutter', help: 'Absolute path to the flutter executable.')
      ..addOption(
        'host',
        help:
            'Run the app on a qa host, e.g. ws://127.0.0.1:7777 through an SSH tunnel, with the token in '
            'QA_HOST_TOKEN; "none" runs here even when the project file names a host.',
      )
      ..addOption(
        'host-project',
        help: 'The project folder (the one holding .qa/) on the host; --project and --binary are then host paths.',
      )
      ..addOption('out', help: 'Folder for run output (default: <app root>/qa-out with a project file, else qa-out).');
  }

  late final ProjectFile? projectFile = _loadProjectFile();

  ProjectFile? _loadProjectFile() {
    final path = projectFilePath(argResults!['config'] as String?);
    return path == null ? null : ProjectFile.load(path);
  }

  /// Command-line values over the project file's, over the defaults.
  ProjectConfig configFromArgs() {
    final r = argResults!;
    final base = projectFile?.config;
    final project = r['project'] as String?;
    final binary = r['binary'] as String?;
    if (project != null && binary != null) throw UsageException('pass only one of --project or --binary', usage);
    if (project == null && binary == null && base == null) {
      throw UsageException('pass --project or --binary, or add .qa/project.yaml (or pass --config)', usage);
    }
    final host = hostFromArgs();
    // A host's paths are its own; they are passed on as given.
    String hostOrLocal(String path) => host == null ? p.absolute(path) : path;
    final fromFlags = project != null || binary != null;
    final fromFile = fromFlags ? null : projectFile!.configWithHost(host);
    final config = ProjectConfig(
      name: base?.name ?? p.basename(project ?? binary!),
      source: fromFlags ? (project == null ? null : hostOrLocal(project)) : fromFile!.source,
      binary: fromFlags ? (binary == null ? null : hostOrLocal(binary)) : fromFile!.binary,
      mode: r['mode'] != null ? BuildMode.values.byName(r['mode'] as String) : base?.mode ?? BuildMode.debug,
      device: r['device'] as String? ?? (base == null || base.deviceIsDefault ? null : base.device),
      entrypoint: r['entrypoint'] as String? ?? base?.entrypoint ?? 'lib/main_qa.dart',
      flavor: base?.flavor,
      dartDefines: base?.dartDefines ?? const {},
      env: base?.env ?? const {},
      flutterPath: r['flutter'] as String?,
      host: host,
    );
    // The host's desktop is checked by the session once it knows the host's OS.
    final problems = config.onHostDesktop
        ? const <String>[]
        : ProjectConfig.deviceProblems(
            device: config.device,
            flavor: config.flavor,
            binary: config.binary,
            mode: config.mode,
          );
    if (problems.isNotEmpty) throw UsageException(problems.first, usage);
    return config;
  }

  /// `--host` and `--host-project` over the project file's `host:`.
  /// `--host none` runs on this machine.
  RemoteHostConfig? hostFromArgs() {
    final r = argResults!;
    final url = r['host'] as String?;
    final project = r['host-project'] as String?;
    final base = projectFile?.config.host;
    if (url == 'none') {
      if (project != null) throw UsageException('--host-project needs a host, not --host none', usage);
      return null;
    }
    if (url == null && project == null) return base;
    final Uri? parsed;
    if (url == null) {
      parsed = null;
    } else {
      parsed = Uri.tryParse(url);
      final problem = parsed == null
          ? 'the host url must look like ws://127.0.0.1:7777'
          : RemoteHostConfig.urlProblem(parsed);
      if (problem != null) throw UsageException('--host: $problem', usage);
    }
    final folder = project ?? base?.project;
    if (folder == null) {
      throw UsageException('--host needs --host-project, the project folder on the host', usage);
    }
    return RemoteHostConfig(url: parsed ?? base?.url, project: folder);
  }

  /// The local folder whose `.qa/` holds baselines: none for a run on a
  /// host without a project file, whose `--project` is a host path.
  String? appRoot() => projectFile == null && hostFromArgs() != null
      ? null
      : ProjectFile.appRootFor(projectFile, argResults!['project'] as String?);

  Directory outDir() {
    final explicit = argResults!['out'] as String?;
    final file = projectFile;
    final path = explicit ?? (file == null ? 'qa-out' : p.join(file.appRoot, 'qa-out'));
    return Directory(p.absolute(path))..createSync(recursive: true);
  }
}

class PingCommand extends Command<int> with ProjectOptions {
  PingCommand() {
    addProjectOptions();
  }

  @override
  String get name => 'ping';
  @override
  String get description => 'Launch the app, ping the agent, take one screenshot, stop.';

  @override
  Future<int> run() async {
    final out = outDir();
    final session = await QaSession.launch(configFromArgs(), screenshotDirectory: out.path, log: stderr.writeln);
    final stop = _stopActive = _once(session.stop);
    try {
      final pong = await session.driver.ping();
      stdout.writeln(pong.result);
      stdout.writeln('settled: ${await session.driver.waitForIdle()}');
      stdout.writeln('screenshot: ${await session.driver.screenshot(path: p.join(out.path, 'ping.png'))}');
      return 0;
    } finally {
      await stop();
    }
  }
}

class SmokeCommand extends Command<int> with ProjectOptions {
  SmokeCommand() {
    addProjectOptions();
  }

  @override
  String get name => 'smoke';
  @override
  String get description => 'Run the demo app smoke scenario and write screenshots and smoke.log.';

  @override
  Future<int> run() async {
    final out = outDir();
    final session = await QaSession.launch(configFromArgs(), screenshotDirectory: out.path, log: stderr.writeln);
    final stop = _stopActive = _once(session.stop);
    try {
      final report = await SmokeRunner(
        session.driver,
        outDir: out.path,
        log: stderr.writeln,
      ).run(demoAppSmokeSteps(out.path));
      stdout.writeln(report.toText());
      return report.passed ? 0 : 1;
    } finally {
      await stop();
    }
  }
}

class HostCommand extends Command<int> {
  HostCommand() {
    argParser
      ..addOption('port', defaultsTo: '7777', help: 'Port to listen on, on 127.0.0.1 only.')
      ..addOption('token-file', help: 'File holding the access token (default: ~/.qa/host-token).');
  }

  @override
  String get name => 'host';
  @override
  String get description => 'Launch apps and boot devices on this machine for qa or QAFlow Studio on another one.';

  static String get defaultTokenFile {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? Directory.current.path;
    return p.join(home, '.qa', 'host-token');
  }

  @override
  Future<int> run() async {
    final port = int.tryParse(argResults!['port'] as String);
    if (port == null || port < 0 || port > 65535) throw UsageException('--port must be a port number', usage);
    final tokenFile = p.absolute(argResults!['token-file'] as String? ?? defaultTokenFile);
    var generated = false;
    final token = loadOrCreateHostToken(tokenFile, onGenerated: (_) => generated = true);
    final HostServer server;
    try {
      server = await HostServer.start(port: port, token: token);
    } on SocketException catch (e) {
      stderr.writeln('qa: could not listen on 127.0.0.1:$port: ${e.osError?.message ?? e.message}');
      return 1;
    }
    _stopActive = _once(server.close);
    stdout.writeln('QA host listening on 127.0.0.1:${server.port}');
    stdout.writeln('Anyone with this token can run programs as you on this machine; treat it like an SSH key.');
    if (generated) {
      stdout
        ..writeln()
        ..writeln('Access token (saved in $tokenFile):')
        ..writeln('  $token')
        ..writeln()
        ..writeln('On the client machine:')
        ..writeln('  1. Open a tunnel: ssh -N -L ${server.port}:127.0.0.1:${server.port} <user>@<this machine>')
        ..writeln('  2. Set QA_HOST_TOKEN to the token above, or add the host in QAFlow Studio settings.')
        ..writeln('  3. Add to .qa/project.yaml:')
        ..writeln('       host:')
        ..writeln('         url: ws://127.0.0.1:${server.port}')
        ..writeln('         project: <the project folder on this machine>')
        ..writeln('     or pass --host ws://127.0.0.1:${server.port} --host-project <path>.');
    }
    if (Platform.isWindows) {
      stdout
        ..writeln()
        ..writeln('Windows notes:')
        ..writeln('  - Start qa host from a terminal inside the logged-in desktop (RDP) session, not from SSH.')
        ..writeln('    Apps started from an SSH session run without a desktop.')
        ..writeln('  - Keep the RDP window open (minimised is fine), or before disconnecting run')
        ..writeln('    tscon %sessionname% /dest:console so the desktop keeps rendering.')
        ..writeln('  - Enable OpenSSH Server; the client tunnels with')
        ..writeln('    ssh -N -L ${server.port}:127.0.0.1:${server.port} <user>@<host>.')
        ..writeln('  - The Android emulator needs nested virtualization (WHPX). iOS is not available on Windows.');
    }
    // Runs until SIGINT or SIGTERM, which stop the apps and exit.
    await Completer<void>().future;
    return 0;
  }
}

class ValidateCommand extends Command<int> {
  ValidateCommand() {
    argParser.addOption(
      'config',
      help:
          'Project file whose flow folders to check when no paths are given '
          '(default: .qa/project.yaml in the current folder).',
    );
  }

  @override
  String get name => 'validate';
  @override
  String get description => 'Parse flow files and the project file and report problems without running an app.';
  @override
  String get invocation => 'qa validate [flow files or folders] [--config <file>]';

  @override
  Future<int> run() async {
    var paths = argResults!.rest;
    if (paths.isEmpty) {
      final path = projectFilePath(argResults!['config'] as String?);
      if (path == null) throw UsageException('pass at least one flow file or folder, or add .qa/project.yaml', usage);
      final file = ProjectFile.load(path);
      stdout.writeln('${p.relative(file.path)} OK');
      paths = file.flowFolders;
    }
    return validateFlows(paths, stdout) == 0 ? 0 : 1;
  }
}

class TestCommand extends Command<int> with ProjectOptions {
  TestCommand() {
    addProjectOptions();
    argParser
      ..addOption('include-tags', help: 'Comma-separated tags; run only flows that have one of them.')
      ..addOption('exclude-tags', help: 'Comma-separated tags; skip flows that have any of them.')
      ..addMultiOption('env', help: 'KEY=VALUE variable for flows; repeatable.', splitCommas: false)
      ..addOption('retries', help: 'Retry a failed flow up to this many times (default: the project file, else 0).')
      ..addOption(
        'screenshots',
        allowed: ['failures', 'all', 'none'],
        help: 'When to save screenshots (default: the project file, else failures).',
      )
      ..addOption(
        'baselines',
        allowed: ['record', 'strict', 'update'],
        help:
            'Screenshot baselines: record missing ones, fail on missing ones, or overwrite all '
            '(default: the project file, else record).',
      )
      ..addFlag('verbose', negatable: false, help: 'Print app output and launch details.');
  }

  @override
  String get name => 'test';
  @override
  String get description => 'Run YAML flows against the app.';
  @override
  String get invocation =>
      'qa test [flow files or folders] [--config <file> | --project <dir> | --binary <path>] [options]';

  Set<String>? _tags(String? raw) => raw == null
      ? null
      : {
          for (final t in raw.split(','))
            if (t.trim().isNotEmpty) t.trim(),
        };

  @override
  Future<int> run() async {
    final r = argResults!;
    final file = projectFile;
    final paths = r.rest.isNotEmpty ? r.rest : file?.flowFolders;
    if (paths == null) throw UsageException('pass at least one flow file or folder, or add .qa/project.yaml', usage);

    final Map<String, String> env;
    try {
      env = {...?file?.flowEnv, ...VariableScope.parseAssignments(r['env'] as List<String>)};
    } on FormatException catch (e) {
      throw UsageException(e.message, usage);
    }
    final missing = <String>[];
    for (final name in file?.secrets ?? const <String>[]) {
      final value = env[name] ?? Platform.environment[name];
      if (value == null) {
        missing.add(name);
      } else {
        env[name] = value;
      }
    }
    if (missing.isNotEmpty) {
      throw UsageException(
        'no value for secret flow variable(s) ${missing.join(', ')}; '
        'pass --env NAME=VALUE or set them in the environment',
        usage,
      );
    }
    final retriesArg = r['retries'] as String?;
    final retries = retriesArg == null ? file?.retries ?? 0 : int.tryParse(retriesArg);
    if (retries == null || retries < 0) throw UsageException('--retries must be a whole number >= 0', usage);
    final screenshotsArg = r['screenshots'] as String?;
    final screenshots = screenshotsArg == null
        ? file?.screenshots ?? ScreenshotPolicy.failures
        : ScreenshotPolicy.values.byName(screenshotsArg);
    final baselines = ProjectFile.baselinesFor(r['baselines'] as String?, file);
    final appRoot = this.appRoot();

    final parser = FlowParser();
    final flows = <Flow>[];
    var parseErrors = 0;
    for (final path in discoverFlowFiles(paths)) {
      try {
        flows.add(parser.parseFile(path));
      } on FlowParseException catch (e) {
        parseErrors++;
        stderr.writeln('${p.relative(e.file)}:${e.line}:${e.column}: ${e.message}');
      }
    }
    if (parseErrors > 0) return 1;
    final selected = selectFlows(
      flows,
      include: _tags(r['include-tags'] as String?) ?? file?.includeTags ?? const {},
      exclude: _tags(r['exclude-tags'] as String?) ?? file?.excludeTags ?? const {},
    );
    if (selected.isEmpty) {
      stderr.writeln('qa: no flows to run');
      return 1;
    }

    final config = configFromArgs();
    final verbose = r['verbose'] as bool;
    final run = await TestRun.start(
      TestRunRequest(
        config: config,
        flows: selected,
        parser: parser,
        outDir: outDir().path,
        env: env,
        retries: retries,
        screenshots: screenshots,
        appRoot: appRoot,
        baselines: baselines,
        log: (m) {
          // ConsoleReporter prints [app] lines itself, from the AppLog events
          // FlowRunner emits off session.logs (subscribed before start(), so
          // this covers launch output too); printing them here as well would
          // duplicate every one of them under --verbose.
          if (m.startsWith('[app]')) return;
          if (verbose || !m.startsWith('[vm]')) stderr.writeln(m);
        },
      ),
    );
    // A second stop also stops the session; done then waits for it and
    // for the reports.
    _stopActive = _once(() async {
      run
        ..stop()
        ..stop();
      await run.done;
    });
    final console = ConsoleReporter(stdout, verbose: verbose);
    await for (final e in run.events) {
      console.onEvent(e);
    }
    final outcome = await run.done;
    stdout
      ..writeln('Report: ${p.relative(outcome.htmlPath)}')
      ..writeln('JUnit:  ${p.relative(outcome.junitPath)}');
    return outcome.isSuccess ? 0 : 1;
  }
}
