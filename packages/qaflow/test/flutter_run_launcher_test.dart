import 'dart:convert';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'fake_process.dart';

void main() {
  late FakeProcess process;
  late List<String> capturedArgs;
  late String? capturedCwd;
  late bool capturedShell;

  FlutterRunLauncher launcher({
    ProjectConfig? config,
    Duration startTimeout = const Duration(minutes: 5),
    Duration stopTimeout = const Duration(seconds: 10),
  }) => FlutterRunLauncher(
    config: config ?? ProjectConfig(name: 'demo', source: '/p/demo', device: 'macos'),
    sdk: FlutterSdk('/sdk/bin/flutter', isWindows: false),
    processStarter: (exe, args, {workingDirectory, environment, runInShell = false}) async {
      capturedArgs = [exe, ...args];
      capturedCwd = workingDirectory;
      capturedShell = runInShell;
      return process;
    },
    startTimeout: startTimeout,
    stopTimeout: stopTimeout,
  );

  test('deviceId overrides the config device in -d', () {
    final l = FlutterRunLauncher(
      config: ProjectConfig(name: 'demo', source: '/app', device: 'ios:iPhone 17 Pro'),
      sdk: FlutterSdk('/flutter/bin/flutter', isWindows: false),
      deviceId: 'F178848D',
    );
    expect(l.arguments.sublist(2, 4), ['-d', 'F178848D']);
  });

  void emitStartup({String mode = 'debug', bool supportsRestart = true}) {
    process.emit('Launching lib/main_qa.dart on macOS in $mode mode...');
    process.emit('[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]');
    process.emit(
      '[{"event":"app.start","params":{"appId":"a1","deviceId":"macos","mode":"$mode","supportsRestart":$supportsRestart}}]',
    );
    process.emit('[{"event":"app.debugPort","params":{"appId":"a1","port":5,"wsUri":"ws://127.0.0.1:5/ws"}}]');
    process.emit('[{"event":"app.log","params":{"appId":"a1","log":"hello from app"}}]');
    process.emit('[{"event":"app.started","params":{"appId":"a1"}}]');
  }

  setUp(() => process = FakeProcess());

  test('builds the flutter run command from the config', () async {
    final future = launcher(
      config: ProjectConfig(
        name: 'demo',
        source: '/p/demo',
        device: 'macos',
        mode: BuildMode.profile,
        flavor: 'dev',
        dartDefines: {'API': 'x'},
      ),
    ).start();
    emitStartup(mode: 'profile', supportsRestart: false);
    final app = await future;
    expect(capturedArgs, [
      '/sdk/bin/flutter',
      'run',
      '--machine',
      '-d',
      'macos',
      '--profile',
      '-t',
      'lib/main_qa.dart',
      '--flavor',
      'dev',
      '--dart-define=API=x',
    ]);
    expect(capturedCwd, '/p/demo');
    expect(capturedShell, isFalse);
    expect(app.appId, 'a1');
    expect(app.wsUri.toString(), 'ws://127.0.0.1:5/ws');
    expect(app.mode, 'profile');
    expect(app.supportsRestart, isFalse);
  });

  test('forwards app.log, stderr and non-frame stdout lines to logs', () async {
    final future = launcher().start();
    emitStartup();
    final app = await future;
    // logs is a broadcast stream: only lines emitted after subscribing arrive.
    final logs = <String>[];
    final sub = app.logs.listen(logs.add);
    process.emit('[{"event":"app.log","params":{"appId":"a1","log":"later log"}}]');
    process.emitErr('warning: something');
    process.emit('plain text line');
    await Future<void>.delayed(Duration.zero);
    expect(logs, containsAll(['later log', 'warning: something', 'plain text line']));
    await sub.cancel();
  });

  test('stop sends app.stop, closes stdin and waits for exit', () async {
    final future = launcher().start();
    emitStartup();
    final app = await future;
    final stopFuture = app.stop();
    final line = await process.stdinLines.first;
    expect(line, '[{"id":1,"method":"app.stop","params":{"appId":"a1"}}]');
    process.emit('[{"id":1,"result":true}]');
    process.exitWith(0);
    await stopFuture;
    expect(process.kills, isEmpty);
  });

  test('kills the process when startup times out waiting for app.start', () async {
    final future = launcher(
      startTimeout: const Duration(milliseconds: 20),
      stopTimeout: const Duration(milliseconds: 20),
    ).start();
    await expectLater(future, throwsA(isA<LaunchException>()));
    expect(process.kills, isNotEmpty, reason: 'the abandoned flutter run process must be killed');
  });

  test('stop force-kills when app.stop is unanswered and the process never exits on stdin close', () async {
    final future = launcher(stopTimeout: const Duration(milliseconds: 20)).start();
    emitStartup();
    final app = await future;
    // The fake never answers app.stop and never exits after stdin closes;
    // stop() must still complete, bounded by stopTimeout, by killing it.
    await app.stop();
    expect(process.kills, isNotEmpty);
  });

  test('fails when the process exits before app.start', () async {
    // Short stopTimeout: the failure path now closes stdin and bounds the
    // exit wait before rethrowing, and nothing here drains stdinLines to
    // let the fake's close() resolve quickly on its own.
    final future = launcher(stopTimeout: const Duration(milliseconds: 20)).start();
    process.emit('Error: No devices found');
    process.exitWith(1);
    await expectLater(
      future,
      throwsA(
        isA<LaunchException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Error: No devices found'), contains('code 1')),
        ),
      ),
    );
  });

  test('restart is refused when unsupported', () async {
    final future = launcher().start();
    emitStartup(mode: 'profile', supportsRestart: false);
    final app = await future;
    expect(() => app.restart(), throwsA(isA<LaunchException>()));
  });

  Future<void> answerNextRequest(Object result) async {
    final line = await process.stdinLines.first;
    final id = ((jsonDecode(line) as List).first as Map)['id'];
    process.emit(
      jsonEncode([
        {'id': id, 'result': result},
      ]),
    );
  }

  test('restart succeeds when the daemon reports code 0', () async {
    final future = launcher().start();
    emitStartup();
    final app = await future;
    final restart = app.restart();
    await answerNextRequest({'code': 0, 'message': ''});
    await restart;
  });

  test('restart times out when the daemon never answers app.restart', () async {
    final future = launcher(startTimeout: const Duration(milliseconds: 200)).start();
    emitStartup();
    final app = await future;
    // The fake never answers app.restart, unlike answerNextRequest in the
    // other restart tests.
    await expectLater(
      app.restart(),
      throwsA(
        isA<LaunchException>().having((e) => e.message, 'message', contains('hot restart did not finish within')),
      ),
    );
  });

  test('restart throws when the daemon reports a failure', () async {
    final future = launcher().start();
    emitStartup();
    final app = await future;
    final restart = app.restart();
    await answerNextRequest({'code': 1, 'message': 'compile error in main.dart'});
    await expectLater(
      restart,
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('compile error'))),
    );
  });

  test('ignores app.progress, app.devTools and app.dtd events during startup', () async {
    // Matches the extra frames the real daemon interleaves per
    // docs/m0-machine-transcript.md: they must not break or stall startup.
    final future = launcher().start();
    process.emit('Launching lib/main_qa.dart on macOS in profile mode...');
    process.emit('[{"event":"daemon.connected","params":{"version":"0.6.1","pid":315}}]');
    process.emit(
      '[{"event":"app.start","params":{"appId":"a1","deviceId":"macos","directory":"/p/demo","supportsRestart":false,"launchMode":"run","mode":"profile"}}]',
    );
    process.emit(
      '[{"event":"app.progress","params":{"appId":"a1","id":"0","progressId":null,"message":"Building macOS application...","finished":false}}]',
    );
    process.emit('[{"event":"app.progress","params":{"appId":"a1","id":"0","progressId":null,"finished":true}}]');
    process.emit(
      '[{"event":"app.debugPort","params":{"appId":"a1","port":5,"wsUri":"ws://127.0.0.1:5/68_z6Gh3UFk=/ws"}}]',
    );
    process.emit(
      '[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:5/68_z6Gh3UFk=/devtools/?uri=ws://127.0.0.1:5/68_z6Gh3UFk=/ws"}}]',
    );
    process.emit('[{"event":"app.dtd","params":{"appId":"a1","uri":"ws://127.0.0.1:6/xJvTq4WODaQ="}}]');
    process.emit('[{"event":"app.started","params":{"appId":"a1"}}]');

    final app = await future;
    expect(app.appId, 'a1');
    expect(app.wsUri.toString(), 'ws://127.0.0.1:5/68_z6Gh3UFk=/ws');
  });
}
