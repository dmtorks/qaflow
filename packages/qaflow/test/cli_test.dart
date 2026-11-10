import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'host_fakes.dart';

/// Runs bin/qa.dart as a process. Each call compiles the CLI, so this file
/// keeps to cases that need no app launch.
void main() {
  final script = p.absolute('bin', 'qa.dart');
  late Directory app;

  setUp(() {
    app = Directory.systemTemp.createTempSync('qa_cli');
    File(p.join(app.path, '.qa', 'flows', 'a.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('- launchApp\n');
  });
  tearDown(() => app.deleteSync(recursive: true));

  void projectFile(String yaml) => File(p.join(app.path, '.qa', 'project.yaml')).writeAsStringSync(yaml);

  Future<ProcessResult> qa(List<String> args, {Map<String, String>? environment}) =>
      Process.run(Platform.resolvedExecutable, [script, ...args], workingDirectory: app.path, environment: environment);

  test('validate with no paths checks the project file and its flow folders', () async {
    projectFile('app:\n  source: .\n');
    final r = await qa(['validate']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(r.stdout, contains('.qa/project.yaml OK'));
    expect(r.stdout, contains('1 flow file(s) OK'));
  });

  test('a project file error names its line and column and exits 1', () async {
    projectFile('app:\n  source: .\n  sorce: x\n');
    final r = await qa(['validate']);
    expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
    expect(r.stderr, contains('.qa/project.yaml:3:3: unknown key "sorce" in app'));
  });

  test('test refuses to start without a value for a secret', () async {
    projectFile('app:\n  source: .\nflows:\n  secrets: [QA_CLI_TEST_SECRET]\n');
    final r = await qa(['test']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
    expect(r.stderr, contains('QA_CLI_TEST_SECRET'));
  });

  test('a secret from the environment lets the run reach the app launch', () async {
    projectFile('app:\n  source: .\nflows:\n  secrets: [QA_CLI_TEST_SECRET]\n');
    final r = await qa(['test', '--flutter', '/nonexistent/flutter'], environment: {'QA_CLI_TEST_SECRET': 'x'});
    expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
    expect(r.stderr, contains('flutter executable not found at /nonexistent/flutter'));
    expect(Directory(p.join(app.path, 'qa-out')).listSync(), isEmpty);
  });

  test('test with no paths and no project file is a usage error', () async {
    final r = await qa(['test']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
  });

  test('an unknown --baselines mode is a usage error', () async {
    final r = await qa(['test', '.qa/flows', '--project', '.', '--baselines', 'sometimes']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
  });

  test('--project and --binary together are a usage error', () async {
    final r = await qa(['test', '.qa/flows', '--project', '.', '--binary', 'x.app']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
  });

  test('an unknown --device is a usage error', () async {
    final r = await qa(['test', '.qa/flows', '--project', '.', '--device', 'iPhone']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
    expect(r.stderr, contains('unknown device "iPhone"'));
  });

  test('--binary with a mobile --device is a usage error', () async {
    final r = await qa(['test', '.qa/flows', '--binary', 'x.app', '--device', 'ios:iPhone 17 Pro']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
    expect(r.stderr, contains('prebuilt apps are not supported on mobile devices yet'));
  });

  test('--mode profile with an iOS --device is a usage error', () async {
    final r = await qa(['test', '.qa/flows', '--project', '.', '--device', 'ios:iPhone 17 Pro', '--mode', 'profile']);
    expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
    expect(r.stderr, contains('profile mode is not supported on iOS simulators; use debug'));
  });

  group('--host', () {
    /// A loopback URL with nothing listening.
    Future<String> closedHost() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return 'ws://127.0.0.1:$port';
    }

    test('a configured host without QA_HOST_TOKEN says where the token comes from', () async {
      projectFile('app:\n  source: .\nhost:\n  url: ${await closedHost()}\n  project: /srv/app\n');
      final r = await qa(['ping'], environment: {'QA_HOST_TOKEN': ''});
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains('qa: Set QA_HOST_TOKEN to the token qa host printed'));
    });

    test('the project file host is used, and --host overrides it', () async {
      final configured = await closedHost();
      projectFile('app:\n  source: .\nhost:\n  url: $configured\n  project: /srv/app\n');
      var r = await qa(['ping'], environment: {'QA_HOST_TOKEN': 't'});
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains("Can't reach the QA host at $configured. Is the SSH tunnel open?"));

      final flag = await closedHost();
      r = await qa(['ping', '--host', flag], environment: {'QA_HOST_TOKEN': 't'});
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains("Can't reach the QA host at $flag."));
    });

    test('--host none runs here even when the project file names a host', () async {
      projectFile('app:\n  source: .\nhost:\n  url: ${await closedHost()}\n  project: /srv/app\n');
      final r = await qa(['ping', '--host', 'none', '--flutter', '/nonexistent/flutter']);
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains('flutter executable not found at /nonexistent/flutter'));
    });

    test('a bad --host or a stray --host-project is a usage error', () async {
      projectFile('app:\n  source: .\n');
      var r = await qa(['ping', '--host', 'http://127.0.0.1:7777']);
      expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains('ws://127.0.0.1:7777'));
      r = await qa(['ping', '--host', 'ws://127.0.0.1:7777']);
      expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains('--host needs --host-project'));
      r = await qa(['ping', '--host', 'none', '--host-project', '/srv/app']);
      expect(r.exitCode, 64, reason: '${r.stdout}${r.stderr}');
    });

    test('the app is launched on the host with its paths as written', () async {
      final hostSide = Directory.systemTemp.createTempSync('qa_cli_host');
      addTearDown(() => hostSide.deleteSync(recursive: true));
      Directory(p.join(hostSide.path, 'app_src')).createSync();
      final launched = <ProjectConfig>[];
      final server = await HostServer.start(
        port: 0,
        token: 'cli-token',
        devices: FakeDevices(),
        launcherFor: (config, flutterId) {
          launched.add(config);
          // Exits at once, so the CLI gives up without a VM service.
          return FakeLauncher(() => FakeApp()..exit.complete(3));
        },
      );
      addTearDown(server.close);
      // app_src exists only on the "host", so resolving it here would fail there.
      projectFile('app:\n  source: app_src\n  entrypoint: lib/qa.dart\n');
      final r = await qa(
        ['ping', '--host', 'ws://127.0.0.1:${server.port}', '--host-project', hostSide.path],
        environment: {'QA_HOST_TOKEN': 'cli-token'},
      );
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr, contains('exited with code 3'));
      expect(launched.single.source, p.join(hostSide.path, 'app_src'));
      expect(launched.single.entrypoint, 'lib/qa.dart');
    });
  });
}
