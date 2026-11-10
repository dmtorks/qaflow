import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'fake_process.dart';
import 'host_fakes.dart';

const token = 'secret-token';

void main() {
  late HostServer host;
  late FakeDevices devices;
  late List<(ProjectConfig, String)> launches;
  late List<FakeApp> apps;
  late Directory project;

  Uri? appWsUri;

  Future<HostServer> startHost({
    Duration grace = const Duration(seconds: 10),
    Duration ping = const Duration(seconds: 5),
  }) async => host = await HostServer.start(
    port: 0,
    token: token,
    devices: devices,
    disconnectGrace: grace,
    pingInterval: ping,
    launcherFor: (config, flutterId) {
      launches.add((config, flutterId));
      return FakeLauncher(() {
        final app = FakeApp(appWsUri);
        apps.add(app);
        return app;
      });
    },
  );

  setUp(() async {
    devices = FakeDevices();
    launches = [];
    apps = [];
    project = await Directory.systemTemp.createTemp('qa_host_test');
    await Directory(p.join(project.path, 'app')).create();
    await startHost();
  });

  tearDown(() async {
    await host.close();
    await project.delete(recursive: true);
  });

  Map<String, Object?> startParams({String flutterId = 'macos', Map<String, Object?>? app}) => {
    'project': project.path,
    'app': app ?? {'source': 'app', 'mode': 'debug', 'dartDefines': <String, String>{}, 'env': <String, String>{}},
    'flutterId': flutterId,
  };

  group('authentication', () {
    Future<int> status(String query) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:${host.port}/control$query'));
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    test('a missing token gets 401', () async {
      expect(await status(''), 401);
    });

    test('a wrong token gets 401', () async {
      expect(await status('?token=nope'), 401);
      expect(await status('?token=${token}x'), 401);
    });

    test('a WebSocket with a wrong token is not upgraded', () async {
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${host.port}/control?token=bad'),
        throwsA(isA<WebSocketException>()),
      );
    });
  });

  group('control', () {
    late HostClient client;
    setUp(() async => client = await HostClient.connect(host.port));
    tearDown(() => client.close());

    test('hello returns the protocol, os, osVersion and qaVersion', () async {
      final r = await client.result('hello', {'protocol': hostProtocolVersion});
      expect(r['protocol'], hostProtocolVersion);
      expect(r['os'], Platform.operatingSystem);
      expect(r['osVersion'], DeviceInfo.hostVersion(Platform.operatingSystemVersion));
      expect(r['qaVersion'], qaVersion);
    });

    test('a mismatched protocol gets the verbatim message', () async {
      final e = await client.error('hello', {'protocol': hostProtocolVersion + 1});
      expect(e.code, HostError.protocolMismatch);
      expect(
        e.message,
        'QA host speaks protocol $hostProtocolVersion; this qa speaks ${hostProtocolVersion + 1}. '
        'Update qa on both machines.',
      );
    });

    test('an unknown method gets -32601', () async {
      final e = await client.error('nope', {});
      expect(e.code, -32601);
    });

    test('devices.list goes through Devices, with booted on the wire', () async {
      final r = await client.result('devices.list', {});
      final listed = [for (final d in r['devices']! as List) deviceInfoFromWire((d as Map).cast())];
      expect(
        [for (final d in listed) (d.id, d.booted, d.osVersion)],
        [('macos', true, '27.0'), ('Pixel_8', false, 'Android 14 (API 34)')],
      );
      expect(r['problems'], [
        {'platform': 'ios', 'message': 'no xcrun'},
      ]);
    });

    test('devices.resolve goes through Devices and sends devices.booting', () async {
      final booting = client.notifications.firstWhere((n) => n.method == 'devices.booting');
      final r = await client.result('devices.resolve', {'device': 'android:Pixel_8'});
      expect(r['flutterId'], 'emulator-5554');
      expect(deviceInfoFromWire((r['info']! as Map).cast()).name, 'Pixel 8');
      final info = deviceInfoFromWire(((await booting).params['info']! as Map).cast());
      expect((info.id, info.booted), ('Pixel_8', false));
      expect(devices.resolved.single.toString(), 'android:Pixel_8');
    });

    test('a bad device string is invalid params', () async {
      final e = await client.error('devices.resolve', {'device': 'nokia'});
      expect(e.code, HostError.invalidParams);
      expect(e.message, contains('unknown device'));
    });

    test('a device tool failure is code 1 with its message', () async {
      devices.failResolve = DeviceToolException('adb is missing');
      final e = await client.error('devices.resolve', {'device': 'android:Pixel_8'});
      expect((e.code, e.message), (1, 'adb is missing'));
    });

    test('device.* calls the resolved device controller', () async {
      await client.result('devices.resolve', {'device': 'android:Pixel_8'});
      await client.result('device.setOrientation', {'flutterId': 'emulator-5554', 'orientation': 'landscapeLeft'});
      await client.result('device.resetOrientation', {'flutterId': 'emulator-5554'});
      await client.result('device.openLink', {'flutterId': 'emulator-5554', 'link': 'demo://cart'});
      expect(devices.controller.calls, ['setOrientation landscapeLeft', 'resetOrientation', 'openLink demo://cart']);
    });

    test('device.setOrientation runs only adb for a real Android controller', () async {
      const adb = '/sdk/platform-tools/adb';
      final run = FakeRunner()
        ..on('$adb -s emulator-5554 shell settings put system accelerometer_rotation 0')
        ..on('$adb -s emulator-5554 shell settings put system user_rotation 1');
      devices.androidController = AndroidDeviceController(
        'emulator-5554',
        sdk: const AndroidSdk('/sdk'),
        run: run.call,
      );
      await client.result('devices.resolve', {'device': 'android:Pixel_8'});
      await client.result('device.setOrientation', {'flutterId': 'emulator-5554', 'orientation': 'landscapeLeft'});
      expect(run.calls, [
        '$adb -s emulator-5554 shell settings put system accelerometer_rotation 0',
        '$adb -s emulator-5554 shell settings put system user_rotation 1',
      ]);
    });

    test('device.* on a device that was never resolved is code 1', () async {
      final e = await client.error('device.resetOrientation', {'flutterId': 'emulator-5554'});
      expect(e.code, 1);
    });

    test('app.start launches through the factory and forwards logs and exit', () async {
      final r = await client.result('app.start', startParams());
      final appId = r['appId']! as String;
      expect(r, {'appId': appId, 'mode': 'debug', 'supportsRestart': true});
      expect(launches.single.$2, 'macos');
      expect(host.launchedApps.keys, [appId]);
      expect(host.launchedApps[appId]!.wsUri, apps.single.wsUri);

      final log = client.notifications.firstWhere((n) => n.method == 'app.log');
      apps.single.logs.add('hello from the app');
      expect((await log).params, {'appId': appId, 'line': 'hello from the app'});

      final exit = client.notifications.firstWhere((n) => n.method == 'app.exit');
      apps.single.exit.complete(3);
      expect((await exit).params, {'appId': appId, 'code': 3});
      expect(host.launchedApps, isEmpty);
    });

    test('the internal VM-service URI is not in the app.start result', () async {
      final r = await client.result('app.start', startParams());
      expect(r.toString(), isNot(contains('authcode')));
    });

    test('app.stop and app.restart go through the launched app', () async {
      final appId = (await client.result('app.start', startParams()))['appId']! as String;
      await client.result('app.restart', {'appId': appId});
      expect(apps.single.restarts, 1);
      await client.result('app.stop', {'appId': appId});
      expect(apps.single.stops, 1);
      expect(host.launchedApps, isEmpty);
      final e = await client.error('app.restart', {'appId': appId});
      expect(e.code, 1);
    });

    test('relative app paths resolve against project', () async {
      await client.result(
        'app.start',
        startParams(
          app: {
            'source': 'app',
            'entrypoint': 'lib/main_qa.dart',
            'mode': 'profile',
            'flavor': 'demo',
            'dartDefines': {'A': '1'},
            'env': {'B': '2'},
          },
        ),
      );
      final config = launches.single.$1;
      expect(config.source, p.join(project.path, 'app'));
      expect(config.entrypoint, 'lib/main_qa.dart');
      expect(config.name, p.basename(project.path));
      expect(config.mode, BuildMode.profile);
      expect(config.flavor, 'demo');
      expect(config.dartDefines, {'A': '1'});
      expect(config.env, {'B': '2'});
    });

    test('a relative binary resolves against project', () async {
      File(p.join(project.path, 'build', 'demo')).createSync(recursive: true);
      await client.result('app.start', startParams(app: {'binary': 'build/demo', 'mode': 'debug'}));
      expect(launches.single.$1.binary, p.join(project.path, 'build', 'demo'));
    });

    test('an app source missing on the host is code 1', () async {
      final e = await client.error('app.start', startParams(app: {'source': 'missing', 'mode': 'debug'}));
      expect(e.code, 1);
      expect(e.message, contains(p.join(project.path, 'missing')));
      expect(launches, isEmpty);
    });

    test('a launch failure is code 1 with its message', () async {
      await host.close();
      host = await HostServer.start(
        port: 0,
        token: token,
        devices: devices,
        launcherFor: (_, _) => FakeLauncher(() => throw LaunchException('no flutter')),
      );
      await client.close();
      client = await HostClient.connect(host.port);
      final e = await client.error('app.start', startParams());
      expect((e.code, e.message), (1, 'no flutter'));
    });
  });

  group('one client at a time', () {
    test('a second client is refused, and accepted after the first closes', () async {
      final first = await HostClient.connect(host.port);
      final second = await WebSocket.connect('ws://127.0.0.1:${host.port}/control?token=$token');
      await second.drain<void>();
      expect(second.closeCode, hostInUseCloseCode);
      expect(second.closeReason, 'QA host is in use by another client');

      await first.close();
      final third = await HostClient.connectWhenFree(host.port);
      expect((await third.result('hello', {'protocol': hostProtocolVersion}))['protocol'], hostProtocolVersion);
      await third.close();
    });
  });

  group('disconnect', () {
    test('a half-open client that misses pongs releases the lock and starts the grace period', () async {
      await host.close();
      await startHost(grace: const Duration(milliseconds: 100), ping: const Duration(milliseconds: 100));
      final silent = await SilentClient.connect(host.port);
      silent.send(HostRequest(1, 'app.start', startParams()).encode());
      await poll(() => apps.isNotEmpty);
      final app = apps.single;
      await app.exit.future.timeout(const Duration(seconds: 5));
      expect(app.stops, 1);
      final next = await HostClient.connectWhenFree(host.port);
      await next.close();
      silent.destroy();
    });

    test('apps are stopped once the grace period runs out', () async {
      await host.close();
      await startHost(grace: const Duration(milliseconds: 200));
      final client = await HostClient.connect(host.port);
      await client.result('app.start', startParams());
      await client.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(apps.single.stops, 0);
      await apps.single.exit.future.timeout(const Duration(seconds: 5));
      expect(apps.single.stops, 1);
      expect(host.launchedApps, isEmpty);
    });

    test('a client that reconnects within the grace period keeps the apps', () async {
      await host.close();
      await startHost(grace: const Duration(milliseconds: 300));
      final client = await HostClient.connect(host.port);
      final appId = (await client.result('app.start', startParams()))['appId'];
      await client.close();
      final again = await HostClient.connectWhenFree(host.port);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(apps.single.stops, 0);
      expect(host.launchedApps.keys, [appId]);
      final log = again.notifications.firstWhere((n) => n.method == 'app.log');
      apps.single.logs.add('still here');
      expect((await log).params['line'], 'still here');
      await again.close();
    });

    test('closing the host stops every app', () async {
      final client = await HostClient.connect(host.port);
      await client.result('app.start', startParams());
      await host.close();
      expect(apps.single.stops, 1);
      await client.close();
    });
  });

  group('VM-service proxy', () {
    late HttpServer upstream;
    late List<String> upstreamPaths;
    late StreamController<WebSocket> appSockets;
    late HostClient control;
    late String appId;

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamPaths = [];
      appSockets = StreamController<WebSocket>();
      upstream.listen((request) async {
        upstreamPaths.add(request.uri.path);
        appSockets.add(await WebSocketTransformer.upgrade(request));
      });
      appWsUri = Uri.parse('ws://127.0.0.1:${upstream.port}/authcode=/ws');
      control = await HostClient.connect(host.port);
      appId = (await control.result('app.start', startParams()))['appId']! as String;
    });

    tearDown(() async {
      await control.close();
      await upstream.close(force: true);
      appWsUri = null;
    });

    Future<(WebSocket, WebSocket)> open() async {
      final client = await WebSocket.connect('ws://127.0.0.1:${host.port}/vm/$appId?token=$token');
      final app = await appSockets.stream.first;
      return (client, app);
    }

    Future<int> status(String path) async {
      final http = HttpClient();
      try {
        final response = await (await http.getUrl(Uri.parse('http://127.0.0.1:${host.port}$path'))).close();
        final body = await response.transform(const SystemEncoding().decoder).join();
        expect(body, isNot(contains('authcode')));
        return response.statusCode;
      } finally {
        http.close(force: true);
      }
    }

    test('forwards text and binary frames both ways', () async {
      final (client, app) = await open();
      final fromClient = Inbox(app);
      final toClient = Inbox(client);
      client.add('{"method":"getVM"}');
      client.add([1, 2, 3]);
      expect(await fromClient.next, '{"method":"getVM"}');
      expect(await fromClient.next, [1, 2, 3]);
      app.add('{"result":{}}');
      app.add([4, 5]);
      expect(await toClient.next, '{"result":{}}');
      final binary = await toClient.next;
      expect(binary, isA<List<int>>());
      expect(binary, [4, 5]);
      await client.close();
    });

    test('the client closing closes the app side', () async {
      final (client, app) = await open();
      final appDone = app.drain<void>();
      await client.close();
      await appDone.timeout(const Duration(seconds: 5));
    });

    test('the app side closing closes the client', () async {
      final (client, app) = await open();
      final clientDone = client.drain<void>();
      await app.close();
      await clientDone.timeout(const Duration(seconds: 5));
    });

    test('the upstream auth code stays on the host', () async {
      final (client, app) = await open();
      expect(upstreamPaths, ['/authcode=/ws']);
      expect(host.launchedApps[appId]!.wsUri.path, '/authcode=/ws');
      await client.close();
      await app.close();
    });

    test('an unknown appId gets 404', () async {
      expect(await status('/vm/nope?token=$token'), 404);
    });

    test('a missing or wrong token gets 401', () async {
      expect(await status('/vm/$appId'), 401);
      expect(await status('/vm/$appId?token=bad'), 401);
    });

    test('an unreachable VM service gets 502 without its URI', () async {
      await upstream.close(force: true);
      final refused = WebSocket.connect('ws://127.0.0.1:${host.port}/vm/$appId?token=$token');
      await expectLater(
        refused,
        throwsA(
          isA<WebSocketException>()
              .having((e) => e.toString(), 'toString()', contains('HTTP status code: 502'))
              .having((e) => e.toString(), 'toString()', isNot(contains('authcode'))),
        ),
      );
    });
  });

  group('token file', () {
    int mode(String path) => FileStat.statSync(path).mode & 0x1ff;

    test('is created once with 32 random bytes as hex, owner-only, and reused', () async {
      final path = p.join(project.path, 'nested', 'host-token');
      final generated = <String>[];
      final created = loadOrCreateHostToken(path, onGenerated: generated.add);
      expect(created, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(generated, [created]);
      if (!Platform.isWindows) expect(mode(path), 0x180);
      expect(loadOrCreateHostToken(path, onGenerated: generated.add), created);
      expect(generated, [created]);
      expect(loadOrCreateHostToken(p.join(project.path, 'other')), isNot(created));
    });

    test('leaves no temporary file behind', () {
      final dir = p.join(project.path, 'tokens');
      loadOrCreateHostToken(p.join(dir, 'host-token'));
      expect([for (final f in Directory(dir).listSync()) p.basename(f.path)], ['host-token']);
    });

    test('a folder it creates is owner-only; an existing folder is left alone', () {
      final created = p.join(project.path, 'fresh');
      loadOrCreateHostToken(p.join(created, 'host-token'));
      expect(mode(created), 0x1c0);
      final existing = Directory(p.join(project.path, 'existing'))..createSync();
      Process.runSync('chmod', ['755', existing.path]);
      loadOrCreateHostToken(p.join(existing.path, 'host-token'));
      expect(mode(existing.path), 0x1ed);
    }, skip: Platform.isWindows ? 'POSIX modes' : null);

    test('an existing token file others can read is tightened to 600', () {
      final path = p.join(project.path, 'host-token');
      File(path).writeAsStringSync('abc\n');
      Process.runSync('chmod', ['644', path]);
      expect(loadOrCreateHostToken(path), 'abc');
      expect(mode(path), 0x180);
    }, skip: Platform.isWindows ? 'POSIX modes' : null);

    test('an empty token file gets a new token, reported as generated', () {
      final path = p.join(project.path, 'host-token');
      File(path).writeAsStringSync('');
      final generated = <String>[];
      final token = loadOrCreateHostToken(path, onGenerated: generated.add);
      expect(generated, [token]);
      expect(File(path).readAsStringSync().trim(), token);
    });
  });

  test('qaVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: (\S+)$', multiLine: true).firstMatch(pubspec)![1], qaVersion);
  });
}

/// Waits until [condition] holds, checking every 10 ms for up to 5 s.
Future<void> poll(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within 5 s');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A control client that completes the handshake by hand and then never
/// answers a ping, like one whose network went away while the tunnel's end
/// on the host stayed open.
class SilentClient {
  SilentClient._(this._socket);

  static Future<SilentClient> connect(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final key = base64Encode(List.generate(16, (i) => i));
    socket.write(
      'GET /control?token=$token HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n\r\n',
    );
    final handshake = Completer<void>();
    final received = <int>[];
    socket.listen((bytes) {
      if (handshake.isCompleted) return; // pings, read and left unanswered
      received.addAll(bytes);
      final text = latin1.decode(received);
      if (text.contains('\r\n\r\n')) {
        expect(text, startsWith('HTTP/1.1 101'));
        handshake.complete();
      }
    }, onError: (Object _) {});
    await handshake.future;
    return SilentClient._(socket);
  }

  final Socket _socket;

  /// One masked text frame, as a client must send it.
  void send(String text) {
    final payload = utf8.encode(text);
    const mask = [1, 2, 3, 4];
    _socket.add([
      0x81,
      if (payload.length < 126) 0x80 | payload.length else ...[0x80 | 126, payload.length >> 8, payload.length & 0xff],
      ...mask,
      for (var i = 0; i < payload.length; i++) payload[i] ^ mask[i % 4],
    ]);
  }

  void destroy() => _socket.destroy();
}

/// A control-connection client.
class HostClient {
  HostClient._(this._socket) {
    _socket.listen(
      (data) {
        final message = HostMessage.decode(data as String);
        if (message is HostResponse) _pending.remove(message.id)?.complete(message);
        if (message is HostNotification) _notifications.add(message);
      },
      onDone: () {
        for (final c in _pending.values) {
          c.completeError(StateError('closed: ${_socket.closeCode} ${_socket.closeReason}'));
        }
        _pending.clear();
        _closed.complete();
      },
    );
  }

  /// Connects and says hello; fails if the host is in use.
  static Future<HostClient> connect(int port) async {
    final client = HostClient._(await WebSocket.connect('ws://127.0.0.1:$port/control?token=$token'));
    await client.call('hello', {'protocol': hostProtocolVersion});
    return client;
  }

  /// [connect], retried while the host is in use: the host releases the
  /// lock when it sees the previous client's close, which need not be on
  /// the same tick that client's close completes.
  static Future<HostClient> connectWhenFree(int port, {Duration within = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(within);
    while (true) {
      final socket = await WebSocket.connect('ws://127.0.0.1:$port/control?token=$token');
      final client = HostClient._(socket);
      try {
        await client.call('hello', {'protocol': hostProtocolVersion});
        return client;
      } on StateError {
        if (socket.closeCode != hostInUseCloseCode || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  final WebSocket _socket;
  final _pending = <int, Completer<HostResponse>>{};
  final _notifications = StreamController<HostNotification>.broadcast();
  final _closed = Completer<void>();
  var _nextId = 1;

  Stream<HostNotification> get notifications => _notifications.stream;

  Future<HostResponse> call(String method, Map<String, Object?> params) {
    final id = _nextId++;
    final completer = _pending[id] = Completer<HostResponse>();
    _socket.add(HostRequest(id, method, params).encode());
    return completer.future;
  }

  Future<Map<String, Object?>> result(String method, Map<String, Object?> params) async {
    final r = await call(method, params);
    if (r.error case final e?) fail('$method failed: $e');
    return r.result!;
  }

  Future<HostError> error(String method, Map<String, Object?> params) async {
    final r = await call(method, params);
    return r.error ?? (fail('$method succeeded: ${r.result}'));
  }

  Future<void> close() async {
    await _socket.close();
    await _closed.future;
  }
}

/// Every frame a socket receives, taken in order.
class Inbox {
  Inbox(Stream<Object?> socket) {
    socket.listen((frame) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        _frames.add(frame);
      }
    });
  }

  final _frames = <Object?>[];
  final _waiting = <Completer<Object?>>[];

  Future<Object?> get next {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    final c = Completer<Object?>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }
}
