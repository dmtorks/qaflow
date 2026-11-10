import 'dart:async';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'fake_vm_service.dart';
import 'host_fakes.dart';

const token = 'session-token';

void main() {
  late HostServer server;
  late FakeDevices devices;
  late List<FakeApp> apps;
  late List<ProjectConfig> launched;
  late Uri url;
  late List<(Uri, String)> connects;
  late List<RemoteHost> hosts;

  setUp(() async {
    devices = FakeDevices();
    apps = [];
    launched = [];
    connects = [];
    hosts = [];
    server = await HostServer.start(
      port: 0,
      token: token,
      devices: devices,
      launcherFor: (config, flutterId) {
        launched.add(config);
        return FakeLauncher(() {
          final app = FakeApp();
          apps.add(app);
          return app;
        });
      },
    );
    url = Uri.parse('ws://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    for (final host in hosts) {
      await host.close();
    }
    await server.close();
  });

  Future<RemoteHost> connectHost(Uri url, String token) async {
    connects.add((url, token));
    final host = await RemoteHost.connect(url, token);
    hosts.add(host);
    return host;
  }

  /// The host's project folder must exist there, which on loopback is here.
  ProjectConfig config({String device = 'android:Pixel_8'}) => ProjectConfig(
    name: 'demo',
    source: '.',
    device: device,
    // Never looked at: a session on a host locates no Flutter SDK.
    flutterPath: '/nonexistent/flutter',
    host: RemoteHostConfig(url: url, project: Directory.systemTemp.path),
  );

  FakeVmService agent(List<String> calls) {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (method, args) {
      calls.add('$method $args');
      if (method == 'ext.qa.waitForIdle') return QaResponse.success({'settled': 'idle'}).toJson();
      return QaResponse.success({'mode': 'debug', 'platform': 'Android'}).toJson();
    };
    return fake;
  }

  test('without QA_HOST_TOKEN it fails before connecting', () async {
    await expectLater(
      QaSession.create(config(), environment: const {}, connectHost: connectHost),
      throwsA(
        isA<RemoteHostException>().having(
          (e) => e.message,
          'message',
          'Set QA_HOST_TOKEN to the token qa host printed',
        ),
      ),
    );
    expect(connects, isEmpty);
  });

  test('the token comes from QA_HOST_TOKEN', () async {
    final session = await QaSession.create(
      config(),
      environment: const {'QA_HOST_TOKEN': token},
      connectHost: connectHost,
    );
    expect(connects, [(url, token)]);
    await session.stop();
  });

  test('a hostToken given directly wins over QA_HOST_TOKEN', () async {
    final session = await QaSession.create(
      config(),
      hostToken: token,
      environment: const {'QA_HOST_TOKEN': 'not-this-one'},
      connectHost: connectHost,
    );
    expect(connects, [(url, token)]);
    await session.stop();
  });

  test('devices and launches go through the host, and stop closes it', () async {
    final vmUris = <String>[];
    final calls = <String>[];
    final session = await QaSession.create(
      config(),
      screenshotDirectory: '/client/shots',
      environment: const {'QA_HOST_TOKEN': token},
      connectHost: connectHost,
      connector: (uri) async {
        vmUris.add(uri);
        return agent(calls);
      },
    );
    await session.start();

    expect(devices.resolved.map((t) => '$t'), ['android:Pixel_8']);
    expect(session.device?.id, 'Pixel_8');
    expect(session.deviceController, isA<RemoteDeviceController>());
    expect(launched.single.source, Directory.systemTemp.path);
    expect(vmUris.single, startsWith('ws://127.0.0.1:${server.port}/vm/'));
    expect(vmUris.single, contains('token=$token'));
    // The client's screenshot folder means nothing on the host.
    expect(calls.single, 'ext.qa.ping {}');
    expect(session.driver.inlineScreenshotsOnly, isTrue);

    await session.stop();
    expect(apps.single.stops, 1);
    expect(hosts.single.isClosed, isTrue);
  });

  test('a start after stop connects again', () async {
    final session = await QaSession.create(
      config(),
      environment: const {'QA_HOST_TOKEN': token},
      connectHost: connectHost,
      connector: (_) async => agent([]),
    );
    await session.start();
    await session.stop();
    await session.start();
    expect(connects, hasLength(2));
    expect(devices.resolved, hasLength(2));
    expect(apps, hasLength(2));
    await session.stop();
  });

  test('reconnecting within the grace period stops the apps the lost connection launched', () async {
    final session = await QaSession.create(
      config(),
      environment: const {'QA_HOST_TOKEN': token},
      connectHost: connectHost,
      connector: (_) async => agent([]),
    );
    await session.start();
    // The tunnel drops: the host keeps the app for its grace period.
    await hosts.single.close();
    await session.stop();
    expect(apps.single.stops, 0);

    await session.start();
    expect(connects, hasLength(2));
    expect(apps, hasLength(2));
    expect(apps.first.stops, 1, reason: 'the earlier copy must not keep running');
    expect(apps.last.stops, 0);
    await session.stop();
  });

  group('a host on another OS', () {
    late HttpServer windows;
    late List<String> resolved;

    /// A host that says it is Windows and resolves any device to itself.
    setUp(() async {
      resolved = [];
      windows = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      windows.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((frame) {
          final request = HostMessage.decode(frame as String) as HostRequest;
          final result = switch (request.method) {
            'hello' => {'protocol': hostProtocolVersion, 'os': 'windows', 'osVersion': '10.0'},
            'devices.resolve' => {
              'flutterId': 'windows',
              'info': deviceInfoToWire(
                const DeviceInfo(platform: DevicePlatform.windows, name: 'Windows', id: 'windows', osVersion: '10.0'),
              ),
            },
            _ => <String, Object?>{},
          };
          if (request.method == 'devices.resolve') resolved.add(request.params['device']! as String);
          socket.add(HostResponse.success(request.id, result).encode());
        });
      });
    });
    tearDown(() => windows.close(force: true));

    ProjectConfig onWindows({String? device, String? flavor}) => ProjectConfig(
      name: 'demo',
      source: '.',
      device: device,
      flavor: flavor,
      host: RemoteHostConfig(url: Uri.parse('ws://127.0.0.1:${windows.port}'), project: r'C:\src\demo'),
    );

    test('a config with no device runs on the host\'s desktop', () async {
      final session = await QaSession.create(
        onWindows(),
        environment: const {'QA_HOST_TOKEN': token},
        connectHost: connectHost,
      );
      expect(session.config.device, 'windows');
      expect((await session.prepareDevice()).platform, DevicePlatform.windows);
      expect(resolved, ['windows']);
      await session.stop();
    });

    test("a flavor with no device is checked against the host's OS after hello", () async {
      await expectLater(
        QaSession.create(
          onWindows(flavor: 'dev'),
          environment: const {'QA_HOST_TOKEN': token},
          connectHost: connectHost,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('flavor is only supported on macos, ios and android devices, not windows'),
          ),
        ),
      );
      expect(connects, hasLength(1), reason: "the check waits for the host's OS");
      expect(hosts.single.isClosed, isTrue);
    });

    test('an explicit device is kept', () async {
      final session = await QaSession.create(
        onWindows(device: 'android:Pixel_8'),
        environment: const {'QA_HOST_TOKEN': token},
        connectHost: connectHost,
      );
      expect(session.config.device, 'android:Pixel_8');
      await session.prepareDevice();
      expect(resolved, ['android:Pixel_8']);
      await session.stop();
    });
  });

  test('launch closes the host connection when start fails', () async {
    await expectLater(
      QaSession.launch(
        config(),
        environment: const {'QA_HOST_TOKEN': token},
        connectHost: connectHost,
        // An agent on another protocol version fails the start.
        connector: (_) async => agent([])..responder = (method, args) => {'ok': true, 'v': 99, 'result': {}},
      ),
      throwsA(isA<LaunchException>()),
    );
    expect(hosts.single.isClosed, isTrue);
  });

  test('a relaunch keeps the host connection', () async {
    final session = await QaSession.create(
      config(device: 'macos'),
      environment: const {'QA_HOST_TOKEN': token},
      connectHost: connectHost,
      connector: (_) async => agent([]),
      launcher: CallbackLauncher(() async => FakeApp().app.withoutRestart()),
    );
    await session.start();
    await session.reset();
    expect(connects, hasLength(1));
    expect(hosts.single.isClosed, isFalse);
    await session.stop();
  });
}

class CallbackLauncher implements AppLauncher {
  CallbackLauncher(this._start);
  final Future<LaunchedApp> Function() _start;
  @override
  Future<LaunchedApp> start() => _start();
}

extension on LaunchedApp {
  LaunchedApp withoutRestart() => LaunchedApp(
    appId: appId,
    wsUri: wsUri,
    mode: mode,
    supportsRestart: false,
    logs: logs,
    exitCode: this.exitCode,
    onStop: stop,
  );
}
