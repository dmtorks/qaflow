import 'dart:async';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'fake_vm_service.dart';

class FakeLauncher implements AppLauncher {
  FakeLauncher(this.app);
  final LaunchedApp app;
  int starts = 0;
  @override
  Future<LaunchedApp> start() async {
    starts++;
    return app;
  }
}

LaunchedApp fakeApp(
  List<String> events, {
  bool supportsRestart = true,
  Future<void> Function()? onRestart,
  Stream<String> logs = const Stream.empty(),
  Future<int>? exitCode,
}) => LaunchedApp(
  appId: 'a1',
  wsUri: Uri.parse('ws://127.0.0.1:1/ws'),
  mode: 'debug',
  supportsRestart: supportsRestart,
  logs: logs,
  exitCode: exitCode ?? Completer<int>().future,
  onStop: () async => events.add('stopped'),
  onRestart: onRestart,
);

class CallbackLauncher implements AppLauncher {
  CallbackLauncher(this._start);
  final Future<LaunchedApp> Function() _start;
  @override
  Future<LaunchedApp> start() => _start();
}

FakeVmService agentFake(List<String> events) {
  final fake = FakeVmService(
    isolates: {
      'iso': ['ext.qa.ping'],
    },
  );
  fake.responder = (method, args) {
    events.add(method);
    if (method == 'ext.qa.waitForIdle') return QaResponse.success({'settled': 'idle'}).toJson();
    return QaResponse.success({'mode': 'debug'}).toJson();
  };
  return fake;
}

class FakeManager extends DeviceManager {
  FakeManager(this.ready, {this.gate}) : super(isMacOS: true, host: DevicePlatform.macos);
  final ReadyDevice ready;
  final Future<void>? gate;
  final List<String> resolved = [];

  @override
  Future<ReadyDevice> resolve(
    DeviceTarget target, {
    void Function(DeviceInfo device)? onBooting,
    CancelSignal? cancel,
  }) async {
    resolved.add(target.toString());
    onBooting?.call(ready.info);
    if (gate != null) {
      await guardDeviceWait(gate!, timeout: const Duration(seconds: 5), what: ready.info.name, cancel: cancel);
    }
    return ready;
  }
}

ReadyDevice readyIos() => const ReadyDevice(
  flutterId: 'U1',
  info: DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17 Pro', id: 'U1', osVersion: 'iOS 26.5'),
  controller: UnsupportedDeviceController(DevicePlatform.ios),
);

void main() {
  test('start launches, connects, pings with the screenshot dir, and stop tears down', () async {
    final events = <String>[];
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) {
      events.add('$m ${a['screenshotDirectory']}');
      return QaResponse.success({'mode': 'debug'}).toJson();
    };
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      screenshotDirectory: '/shots',
      launcher: FakeLauncher(fakeApp(events)),
      connector: (_) async => fake,
    );
    expect(events, ['ext.qa.ping /shots']);
    expect(session.driver.screenshotDirectory, '/shots');
    await session.stop();
    expect(events.last, 'stopped');
  });

  test('prepareDevice resolves once and reports booting', () async {
    final manager = FakeManager(readyIos());
    final session = await QaSession.create(
      ProjectConfig(name: 'demo', source: '/app', device: 'ios:iPhone 17 Pro'),
      launcher: FakeLauncher(fakeApp([])),
      devices: manager,
    );
    final booting = <DeviceInfo>[];
    final info = await session.prepareDevice(onBooting: booting.add);
    await session.prepareDevice();
    expect(info.title, 'iPhone 17 Pro (iOS 26.5)');
    expect(session.device?.id, 'U1');
    expect(manager.resolved, ['ios:iPhone 17 Pro']);
    expect(booting.single.id, 'U1');
  });

  test('stop while waiting for the device cancels the wait', () async {
    final manager = FakeManager(readyIos(), gate: Completer<void>().future);
    final session = await QaSession.create(
      ProjectConfig(name: 'demo', source: '/app', device: 'ios:iPhone 17 Pro'),
      launcher: FakeLauncher(fakeApp([])),
      devices: manager,
    );
    final preparing = session.prepareDevice();
    await Future<void>.delayed(Duration.zero);
    await session.stop();
    await expectLater(
      preparing,
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', 'stopped while waiting for iPhone 17 Pro')),
    );
  });

  test('an agent on the wrong platform stops the app and fails', () async {
    final events = <String>[];
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) => QaResponse.success({'mode': 'debug', 'platform': 'macOS'}).toJson();
    await expectLater(
      QaSession.launch(
        ProjectConfig(name: 'demo', source: '/app', device: 'ios:iPhone 17 Pro'),
        launcher: FakeLauncher(fakeApp(events)),
        connector: (_) async => fake,
        devices: FakeManager(readyIos()),
      ),
      throwsA(
        isA<LaunchException>().having((e) => e.message, 'message', 'expected an iOS app but the agent reports macOS'),
      ),
    );
    expect(events, contains('stopped'));
  });

  test('a connection whose dispose throws still stops the app', () async {
    final events = <String>[];
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) => QaResponse.success({'mode': 'debug'}).toJson();
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: FakeLauncher(fakeApp(events)),
      connector: (_) async => fake,
    );
    fake.disposeError = StateError('dispose boom');
    await expectLater(session.stop(), throwsA(isA<StateError>()));
    expect(events, contains('stopped'));
  });

  test('a protocol version mismatch stops the app and fails', () async {
    final events = <String>[];
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) => {'ok': true, 'v': 99, 'result': {}};
    await expectLater(
      QaSession.launch(
        ProjectConfig(name: 'demo', source: '/p'),
        launcher: FakeLauncher(fakeApp(events)),
        connector: (_) async => fake,
      ),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('protocol'))),
    );
    expect(events, ['stopped']);
    expect(fake.disposeCalls, 1);
  });

  test('a ping failure disposes the connection once and stops the app', () async {
    final events = <String>[];
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) => throw QaException(QaErrorCode.notReady, 'not ready');
    await expectLater(
      QaSession.launch(
        ProjectConfig(name: 'demo', source: '/p'),
        launcher: FakeLauncher(fakeApp(events)),
        connector: (_) async => fake,
      ),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notReady)),
    );
    expect(events, ['stopped']);
    expect(fake.disposeCalls, 1);
  });

  test('invalid config fails before launching', () async {
    final launcher = FakeLauncher(fakeApp([]));
    await expectLater(QaSession.launch(ProjectConfig(name: 'x'), launcher: launcher), throwsA(isA<ArgumentError>()));
    expect(launcher.starts, 0);
  });

  test('fails fast with the exit code and log tail when the app exits before connecting', () async {
    // A binary that crashes on start (bad codesign, a missing dylib, wrong
    // arch, ...) never opens the VM service port, so a connector that keeps
    // refusing every attempt stands in for that: without the app.exitCode
    // race, VmConnection.connect would retry it for the full 30s timeout.
    final events = <String>[];
    final logsController = StreamController<String>.broadcast();
    final exitCompleter = Completer<int>();
    final app = fakeApp(events, supportsRestart: false, logs: logsController.stream, exitCode: exitCompleter.future);

    final stopwatch = Stopwatch()..start();
    final result = QaSession.launch(
      ProjectConfig(name: 'demo', binary: '/b/demo', mode: BuildMode.profile),
      launcher: FakeLauncher(app),
      connector: (_) async => throw Exception('connection refused'),
    );

    // Let QaSession.start()'s continuation reach its app.logs.listen() and
    // app.exitCode.then() registrations (the two statements right after it
    // awaits launcher.start()) before the crash arrives.
    await Future<void>.delayed(Duration.zero);
    logsController
      ..add('Some startup line')
      ..add('dyld: Library not loaded: @rpath/libfoo.dylib');
    // And let both lines actually be delivered to the logs listener before
    // the exit completes, the way dyld's stderr output precedes the process
    // dying in real life.
    await Future<void>.delayed(Duration.zero);
    exitCompleter.complete(1);

    await expectLater(
      result,
      throwsA(
        isA<LaunchException>().having(
          (e) => e.message,
          'message',
          allOf(contains('1'), contains('dyld: Library not loaded')),
        ),
      ),
    );
    stopwatch.stop();
    // The connect timeout defaults to 30s; failing fast means nowhere close to it.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(events, contains('stopped'));
  });

  test('create does not launch; start launches once', () async {
    final events = <String>[];
    final launcher = FakeLauncher(fakeApp(events));
    final session = await QaSession.create(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: launcher,
      connector: (_) async => agentFake(events),
    );
    expect(session.isRunning, isFalse);
    expect(launcher.starts, 0);
    await session.start();
    await session.start();
    expect(session.isRunning, isTrue);
    expect(launcher.starts, 1);
    await session.stop();
    expect(session.isRunning, isFalse);
  });

  test('reset hot restarts, waits for the agent and settles', () async {
    final events = <String>[];
    final app = fakeApp(events, onRestart: () async => events.add('restarted'));
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: FakeLauncher(app),
      connector: (_) async => agentFake(events),
    );
    events.clear();
    await session.reset();
    expect(events, ['restarted', 'ext.qa.ping', 'ext.qa.waitForIdle']);
    await session.stop();
  });

  test('reset with clearState runs the reset hook before restarting', () async {
    final events = <String>[];
    final app = fakeApp(events, onRestart: () async => events.add('restarted'));
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: FakeLauncher(app),
      connector: (_) async => agentFake(events),
    );
    events.clear();
    await session.reset(clearState: true);
    expect(events.take(2), ['ext.qa.resetState', 'restarted']);
    await session.stop();
  });

  test('reset retries waitForIdle through not_ready while the window is briefly hidden', () async {
    final events = <String>[];
    final app = fakeApp(events, onRestart: () async => events.add('restarted'));
    var waitForIdleCalls = 0;
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (method, args) {
      events.add(method);
      if (method == 'ext.qa.waitForIdle') {
        waitForIdleCalls++;
        return waitForIdleCalls < 3
            ? QaResponse.failure(QaErrorCode.notReady, 'not ready').toJson()
            : QaResponse.success({'settled': 'idle'}).toJson();
      }
      return QaResponse.success({'mode': 'debug'}).toJson();
    };
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: FakeLauncher(app),
      connector: (_) async => fake,
      agentTimeout: const Duration(seconds: 5),
    );
    events.clear();
    await session.reset();
    expect(waitForIdleCalls, 3);
    expect(events.last, 'ext.qa.waitForIdle');
    await session.stop();
  });

  test('reset gives up on a not_ready that never recovers, after agentTimeout', () async {
    final events = <String>[];
    final app = fakeApp(events, onRestart: () async => events.add('restarted'));
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (method, args) {
      if (method == 'ext.qa.waitForIdle') return QaResponse.failure(QaErrorCode.notReady, 'not ready').toJson();
      return QaResponse.success({'mode': 'debug'}).toJson();
    };
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: FakeLauncher(app),
      connector: (_) async => fake,
      agentTimeout: const Duration(milliseconds: 300),
    );
    final stopwatch = Stopwatch()..start();
    await expectLater(session.reset(), throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notReady)));
    stopwatch.stop();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    await session.stop();
  });

  test('reset relaunches when hot restart is not supported', () async {
    final events = <String>[];
    var starts = 0;
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: CallbackLauncher(() async {
        starts++;
        return fakeApp(events, supportsRestart: false);
      }),
      connector: (_) async => agentFake(<String>[]),
    );
    final firstDriver = session.driver;
    expect(session.supportsHotRestart, isFalse);
    await session.reset();
    expect(starts, 2);
    expect(events, ['stopped']);
    expect(identical(session.driver, firstDriver), isFalse);
    await session.stop();
  });

  test('logs forwards app output across relaunches', () async {
    final events = <String>[];
    final lines = StreamController<String>.broadcast();
    final session = await QaSession.launch(
      ProjectConfig(name: 'demo', source: '/p'),
      launcher: CallbackLauncher(() async => fakeApp(events, supportsRestart: false, logs: lines.stream)),
      connector: (_) async => agentFake(<String>[]),
    );
    final seen = <String>[];
    final sub = session.logs.listen(seen.add);
    lines.add('before');
    await session.reset();
    lines.add('after');
    await Future<void>.delayed(Duration.zero);
    expect(seen, containsAllInOrder(['before', 'after']));
    await sub.cancel();
    await session.stop();
  });
}
