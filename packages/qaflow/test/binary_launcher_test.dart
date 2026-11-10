import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'fake_process.dart';

/// Mirrors real `plutil -extract CFBundleExecutable raw -o -` output
/// (verified against /usr/bin/plutil on both an XML and a binary-format
/// Info.plist): exit 0 with the bare name on success, exit 1 with a
/// message on stderr and empty stdout for a missing file or a missing key.
ProcessResult _fakePlutil(int exitCode, {String stdout = '', String stderr = ''}) =>
    ProcessResult(0, exitCode, stdout, stderr);

void main() {
  test('engine environment matches what flutter_tools emits', () {
    final env = BinaryLauncher.engineEnvironment(4321, extra: {'MY_VAR': '1'});
    expect(env, {
      'MY_VAR': '1',
      'FLUTTER_ENGINE_SWITCHES': '3',
      'FLUTTER_ENGINE_SWITCH_1': 'enable-dart-profiling=true',
      'FLUTTER_ENGINE_SWITCH_2': 'vm-service-port=4321',
      'FLUTTER_ENGINE_SWITCH_3': 'disable-service-auth-codes=true',
    });
  });

  test('resolves a macOS .app bundle to its executable', () {
    late List<String> args;
    final exe = BinaryLauncher.resolveExecutable(
      '/b/demo_app.app',
      isMacOS: true,
      runPlutil: (a) {
        args = a;
        return _fakePlutil(0, stdout: 'demo_app\n');
      },
    );
    expect(exe, '/b/demo_app.app/Contents/MacOS/demo_app');
    expect(args, ['-extract', 'CFBundleExecutable', 'raw', '-o', '-', '/b/demo_app.app/Contents/Info.plist']);
    expect(BinaryLauncher.resolveExecutable('/b/demo_app', isMacOS: true), '/b/demo_app');
    expect(BinaryLauncher.resolveExecutable(r'C:\b\demo_app.exe', isMacOS: false), r'C:\b\demo_app.exe');
  });

  test('a missing Info.plist raises LaunchException naming the bundle', () {
    expect(
      () => BinaryLauncher.resolveExecutable(
        '/b/demo_app.app',
        isMacOS: true,
        runPlutil: (a) => _fakePlutil(
          1,
          stderr: 'Info.plist: (The file "Info.plist" couldn\'t be opened because there is no such file.)',
        ),
      ),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('/b/demo_app.app'))),
    );
  });

  test('a plist missing CFBundleExecutable raises LaunchException naming the bundle', () {
    expect(
      () => BinaryLauncher.resolveExecutable(
        '/b/demo_app.app',
        isMacOS: true,
        runPlutil: (a) => _fakePlutil(
          1,
          stderr:
              'Info.plist: Could not extract value, error: No value at that key path or '
              'invalid key path: CFBundleExecutable',
        ),
      ),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('/b/demo_app.app'))),
    );
  });

  test('exit 0 with empty output also raises, not just a non-zero exit', () {
    // Guards the exitCode==0/empty-stdout edge on its own; real plutil
    // exercised above (success case) and probed separately always exits
    // non-zero for a missing plist or key, on both XML and binary-format
    // (Xcode's default) Info.plist.
    expect(
      () => BinaryLauncher.resolveExecutable(
        '/b/demo_app.app',
        isMacOS: true,
        runPlutil: (a) => _fakePlutil(0, stdout: ''),
      ),
      throwsA(isA<LaunchException>()),
    );
  });

  test('freePort returns a bindable loopback port', () async {
    final port = await BinaryLauncher.freePort();
    expect(port, greaterThan(0));
  });

  test('start runs the executable with the engine env and stop kills it', () async {
    final process = FakeProcess();
    late Map<String, String> env;
    late String exe;
    final launcher = BinaryLauncher(
      config: ProjectConfig(name: 'demo', binary: '/b/demo', mode: BuildMode.profile, env: {'X': 'y'}),
      processStarter: (e, args, {workingDirectory, environment, runInShell = false}) async {
        exe = e;
        env = environment!;
        return process;
      },
    );
    final app = await launcher.start();
    expect(exe, '/b/demo');
    expect(env['X'], 'y');
    expect(env['FLUTTER_ENGINE_SWITCH_2'], startsWith('vm-service-port='));
    expect(app.wsUri.host, '127.0.0.1');
    expect(app.wsUri.path, '/ws');
    expect(app.supportsRestart, isFalse);
    expect(app.appId, isNull);
    await app.stop();
    expect(process.kills, isNotEmpty);
  });

  test('a release .app fails at once with the rebuild command, before anything starts', () async {
    final dir = Directory.systemTemp.createTempSync('binary_release');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = '${dir.path}/demo.app';
    File('$app/Contents/Frameworks/FlutterMacOS.framework/Resources/Info.plist')
      ..createSync(recursive: true)
      ..writeAsStringSync('<plist><dict><key>BuildMode</key><string>release</string></dict></plist>');
    var started = false;
    final launcher = BinaryLauncher(
      config: ProjectConfig(name: 'demo', binary: app, mode: BuildMode.profile),
      processStarter: (e, args, {workingDirectory, environment, runInShell = false}) async {
        started = true;
        return FakeProcess();
      },
    );
    await expectLater(
      launcher.start(),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('--profile -t lib/main_qa.dart'))),
    );
    expect(started, isFalse);
  });
}
