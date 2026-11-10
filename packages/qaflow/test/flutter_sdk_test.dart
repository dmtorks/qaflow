import 'dart:async';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  test('explicit path wins when it exists', () async {
    final sdk = await FlutterSdk.locate(
      explicitPath: '/x/bin/flutter',
      environment: {'FLUTTER_ROOT': '/y'},
      exists: (p) => p == '/x/bin/flutter',
      isWindows: false,
    );
    expect(sdk.executable, '/x/bin/flutter');
  });

  test('missing explicit path is an error', () async {
    await expectLater(
      FlutterSdk.locate(explicitPath: '/nope', exists: (_) => false, environment: {}, isWindows: false),
      throwsA(isA<LaunchException>()),
    );
  });

  test('falls back to FLUTTER_ROOT, then fvm default, then PATH', () async {
    final root = await FlutterSdk.locate(
      environment: {'FLUTTER_ROOT': '/y', 'HOME': '/h', 'PATH': '/bin'},
      exists: (p) => p == '/y/bin/flutter',
      isWindows: false,
    );
    expect(root.executable, '/y/bin/flutter');

    final fvm = await FlutterSdk.locate(
      environment: {'HOME': '/h', 'PATH': '/bin'},
      exists: (p) => p == '/h/fvm/default/bin/flutter',
      isWindows: false,
    );
    expect(fvm.executable, '/h/fvm/default/bin/flutter');

    final onPath = await FlutterSdk.locate(
      environment: {'HOME': '/h', 'PATH': '/opt/a:/opt/b'},
      exists: (p) => p == '/opt/b/flutter',
      isWindows: false,
    );
    expect(onPath.executable, '/opt/b/flutter');
  });

  test('uses flutter.bat and runInShell on Windows', () async {
    final sdk = await FlutterSdk.locate(
      environment: {'FLUTTER_ROOT': r'C:\sdk'},
      exists: (p) => p == r'C:\sdk\bin\flutter.bat',
      isWindows: true,
    );
    expect(sdk.executable, r'C:\sdk\bin\flutter.bat');
    expect(sdk.runInShell, isTrue);
  });

  test('reports which step found flutter', () async {
    Future<FlutterSdkSource> sourceFor(Map<String, String> env, String found) async =>
        (await FlutterSdk.locate(environment: env, exists: (p) => p == found, isWindows: false)).source;
    expect(await sourceFor({'FLUTTER_ROOT': '/y', 'HOME': '/h'}, '/y/bin/flutter'), FlutterSdkSource.flutterRoot);
    expect(await sourceFor({'HOME': '/h'}, '/h/fvm/default/bin/flutter'), FlutterSdkSource.fvm);
    expect(await sourceFor({'PATH': '/opt/a'}, '/opt/a/flutter'), FlutterSdkSource.path);
    final explicit = await FlutterSdk.locate(
      explicitPath: '/x/flutter',
      exists: (_) => true,
      environment: {},
      isWindows: false,
    );
    expect(explicit.source, FlutterSdkSource.explicit);
  });

  test('asks the login shell last and takes the last line it prints', () async {
    final calls = <(String, List<String>)>[];
    final sdk = await FlutterSdk.locate(
      environment: {'HOME': '/h', 'PATH': '/bin', 'SHELL': '/bin/zsh'},
      exists: (p) => p == '/opt/flutter/bin/flutter',
      isWindows: false,
      runProcess: (exe, args, {runInShell = false}) async {
        calls.add((exe, args));
        return ProcessResult(1, 0, 'Welcome back\n/opt/flutter/bin/flutter\n', '');
      },
    );
    expect(sdk.executable, '/opt/flutter/bin/flutter');
    expect(sdk.source, FlutterSdkSource.loginShell);
    expect(calls.single.$1, '/bin/zsh');
    expect(calls.single.$2, ['-l', '-c', 'command -v flutter']);
  });

  test('ignores login shell output that is not a path, such as an alias', () async {
    await expectLater(
      FlutterSdk.locate(
        environment: {'SHELL': '/bin/zsh'},
        exists: (_) => false,
        isWindows: false,
        runProcess: (exe, args, {runInShell = false}) async =>
            ProcessResult(1, 0, 'flutter: aliased to fvm flutter\n', ''),
      ),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('--flutter'))),
    );
  });

  test('gives up on a login shell that does not answer', () async {
    await expectLater(
      FlutterSdk.locate(
        environment: {'SHELL': '/bin/zsh'},
        exists: (_) => false,
        isWindows: false,
        loginShellTimeout: const Duration(milliseconds: 50),
        runProcess: (exe, args, {runInShell = false}) => Completer<ProcessResult>().future,
      ),
      throwsA(isA<LaunchException>()),
    );
  });

  test('never runs a login shell on Windows', () async {
    await expectLater(
      FlutterSdk.locate(
        environment: {},
        exists: (_) => false,
        isWindows: true,
        runProcess: (exe, args, {runInShell = false}) => fail('the login shell must not run on Windows'),
      ),
      throwsA(isA<LaunchException>()),
    );
  });

  test('version reads flutter --version --machine, skipping text before the JSON', () async {
    final sdk = FlutterSdk('/sdk/bin/flutter', isWindows: false);
    late List<String> args;
    final v = await sdk.version(
      runProcess: (exe, a, {runInShell = false}) async {
        args = a;
        return ProcessResult(
          1,
          0,
          'A new version of Flutter is available!\n'
              '{"frameworkVersion":"3.44.2","channel":"stable","dartSdkVersion":"3.12.2"}\n',
          '',
        );
      },
    );
    expect(args, ['--version', '--machine']);
    expect((v.frameworkVersion, v.dartSdkVersion, v.channel), ('3.44.2', '3.12.2', 'stable'));
  });

  test('version reports a failing flutter', () async {
    final sdk = FlutterSdk('/sdk/bin/flutter', isWindows: false);
    await expectLater(
      sdk.version(runProcess: (exe, a, {runInShell = false}) async => ProcessResult(1, 1, '', 'boom')),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('boom'))),
    );
  });

  test('finds the real flutter and reads its version', () async {
    final FlutterSdk sdk;
    try {
      sdk = await FlutterSdk.locate();
    } on LaunchException {
      markTestSkipped('no flutter on this machine');
      return;
    }
    final v = await sdk.version();
    expect(v.frameworkVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
