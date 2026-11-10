import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'host_fakes.dart';

const token = 'client-token';

void main() {
  late HostServer server;
  late FakeDevices devices;
  late List<FakeApp> apps;
  late Uri url;
  Uri? appWsUri;
  final hosts = <RemoteHost>[];

  Future<RemoteHost> connect([String t = token]) async {
    final host = await RemoteHost.connect(url, t);
    hosts.add(host);
    return host;
  }

  setUp(() async {
    devices = FakeDevices();
    apps = [];
    appWsUri = null;
    server = await HostServer.start(
      port: 0,
      token: token,
      devices: devices,
      launcherFor: (config, flutterId) => FakeLauncher(() {
        final app = FakeApp(appWsUri);
        apps.add(app);
        return app;
      }),
    );
    url = Uri.parse('ws://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    for (final host in hosts) {
      await host.close();
    }
    hosts.clear();
    await server.close();
  });

  Matcher hostException(String message) =>
      throwsA(isA<RemoteHostException>().having((e) => e.message, 'message', message));

  group('RemoteHost.connect', () {
    test('a closed port cannot be reached', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closed = Uri.parse('ws://127.0.0.1:${socket.port}');
      await socket.close();
      await expectLater(
        RemoteHost.connect(closed, token),
        hostException("Can't reach the QA host at $closed. Is the SSH tunnel open?"),
      );
    });

    test('a tunnel with nothing behind it cannot be reached', () async {
      // ssh accepts the local connection, then drops it when the far end refuses.
      final tunnel = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      tunnel.listen((s) => s.destroy());
      final at = Uri.parse('ws://127.0.0.1:${tunnel.port}');
      await expectLater(
        RemoteHost.connect(at, token),
        hostException("Can't reach the QA host at $at. Is the SSH tunnel open?"),
      );
      await tunnel.close();
    });

    test('a wrong token is refused', () async {
      await expectLater(RemoteHost.connect(url, 'wrong'), hostException('The QA host refused the token'));
    });

    test('a host in use by another client says so', () async {
      await connect();
      await expectLater(RemoteHost.connect(url, token), hostException(hostInUseMessage));
    });

    test('exposes the host os and versions', () async {
      final host = await connect();
      expect(host.os, Platform.operatingSystem);
      expect(host.osVersion, DeviceInfo.hostVersion(Platform.operatingSystemVersion));
      expect(host.qaVersion, qaVersion);
    });

    test('a host on another protocol gets the mismatch message', () async {
      final fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fake.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((frame) {
          final r = HostMessage.decode(frame as String) as HostRequest;
          socket.add(
            HostResponse.success(r.id, {
              'protocol': hostProtocolVersion + 1,
              'os': 'linux',
              'osVersion': '6.5',
              'qaVersion': '9.0.0',
            }).encode(),
          );
        });
      });
      await expectLater(
        RemoteHost.connect(Uri.parse('ws://127.0.0.1:${fake.port}'), token),
        hostException(protocolMismatchMessage(host: hostProtocolVersion + 1, client: hostProtocolVersion)),
      );
      await fake.close(force: true);
    });

    test('a connect that times out closes the socket if the upgrade comes late', () async {
      WebSocket? holder;
      final lateUpgrade = Completer<void>();
      var first = true;
      final fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fake.listen((request) async {
        final slow = first;
        first = false;
        if (slow) await Future<void>.delayed(const Duration(milliseconds: 300));
        final socket = await WebSocketTransformer.upgrade(request);
        if (holder != null) {
          await socket.close(hostInUseCloseCode, hostInUseMessage);
          return;
        }
        holder = socket;
        if (slow) lateUpgrade.complete();
        socket.listen(
          (frame) {
            final r = HostMessage.decode(frame as String) as HostRequest;
            socket.add(HostResponse.success(r.id, {'protocol': hostProtocolVersion, 'os': 'linux'}).encode());
          },
          onDone: () {
            if (identical(holder, socket)) holder = null;
          },
        );
      });
      final at = Uri.parse('ws://127.0.0.1:${fake.port}');
      await expectLater(
        RemoteHost.connect(at, token, timeout: const Duration(milliseconds: 100)),
        hostException("Can't reach the QA host at $at. Is the SSH tunnel open?"),
      );
      await lateUpgrade.future;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (holder != null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(holder, isNull, reason: 'the late socket should have been closed');
      final host = await RemoteHost.connect(at, token);
      hosts.add(host);
      expect(host.os, 'linux');
      await fake.close(force: true);
    });

    test('pending calls fail when the host goes away', () async {
      final host = await connect();
      devices.resolveGate = Completer<void>();
      final call = host.call('devices.resolve', {'device': 'android:Pixel_8'});
      await server.close();
      await expectLater(call, throwsA(isA<RemoteHostException>()));
      await host.done;
      await expectLater(host.call('devices.list'), throwsA(isA<RemoteHostException>()));
    });

    test('a request that cannot be sent fails its future rather than throwing', () async {
      final host = await connect();
      late Future<Object?> call;
      expect(() => call = host.call('devices.list', {'bad': Object()}), returnsNormally);
      await expectLater(call, throwsA(isA<JsonUnsupportedObjectError>()));
    });

    test('the host error message comes back as a HostError', () async {
      final host = await connect();
      await expectLater(
        host.call('nope'),
        throwsA(isA<HostError>().having((e) => e.code, 'code', HostError.methodNotFound)),
      );
    });
  });

  group('RemoteDevices', () {
    test('list returns the host DeviceInfo values', () async {
      final list = await RemoteDevices(await connect()).list();
      expect([for (final d in list.devices) (d.id, d.booted)], [('macos', true), ('Pixel_8', false)]);
      expect(list.devices.first.baselineKey(), 'macos-27.0');
      expect([for (final p in list.problems) (p.platform, p.message)], [(DevicePlatform.ios, 'no xcrun')]);
    });

    test('resolve relays onBooting and returns the host device', () async {
      final booting = <DeviceInfo>[];
      final ready = await RemoteDevices(
        await connect(),
      ).resolve(DeviceTarget.parse('android:Pixel_8'), onBooting: booting.add);
      expect([for (final d in booting) (d.id, d.booted)], [('Pixel_8', false)]);
      expect(ready.flutterId, 'emulator-5554');
      expect((ready.info.name, ready.info.booted), ('Pixel 8', true));
      expect(ready.controller, isA<RemoteDeviceController>());
    });

    test('a host failure to resolve is a LaunchException', () async {
      devices.failResolve = DeviceToolException('adb is missing');
      await expectLater(
        RemoteDevices(await connect()).resolve(DeviceTarget.parse('android:Pixel_8')),
        throwsA(isA<LaunchException>().having((e) => e.message, 'message', 'adb is missing')),
      );
    });

    test('cancel stops waiting for a boot', () async {
      devices.resolveGate = Completer<void>();
      final cancel = CancelSignal();
      final ready = RemoteDevices(await connect()).resolve(DeviceTarget.parse('android:Pixel_8'), cancel: cancel);
      cancel.cancel();
      await expectLater(ready, throwsA(isA<LaunchException>()));
      devices.resolveGate!.complete();
    });

    test('an Android controller goes through device.* calls', () async {
      final ready = await RemoteDevices(await connect()).resolve(DeviceTarget.parse('android:Pixel_8'));
      final driver = QaDriver(RecordingTransport(views: [(915, 412)]));
      await ready.controller.setOrientation(ScreenOrientation.landscapeRight, driver);
      await ready.controller.resetOrientation();
      await ready.controller.openLink(Uri.parse('demo://a'));
      expect(devices.controller.calls, ['setOrientation landscapeRight', 'resetOrientation', 'openLink demo://a']);
    });

    test('an Android rotation waits for the views through the client driver', () async {
      final ready = await RemoteDevices(await connect()).resolve(DeviceTarget.parse('android:Pixel_8'));
      final transport = RecordingTransport(views: [(412, 915), (412, 915), (915, 412)]);
      await ready.controller.setOrientation(ScreenOrientation.landscapeLeft, QaDriver(transport));
      expect(devices.controller.calls, ['setOrientation landscapeLeft']);
      expect([for (final c in transport.calls) c.$1], [QaMethod.ping, QaMethod.ping, QaMethod.ping]);
    });

    test('an iOS controller rotates through the agent and opens links on the host', () async {
      final ready = await RemoteDevices(await connect()).resolve(DeviceTarget.parse('ios:iPhone 17'));
      final transport = RecordingTransport();
      await ready.controller.setOrientation(ScreenOrientation.landscapeLeft, QaDriver(transport));
      await ready.controller.resetOrientation();
      await ready.controller.openLink(Uri.parse('demo://b'));
      expect(transport.calls.first.$1, QaMethod.setOrientation);
      expect(transport.calls.first.$2, {'orientation': 'landscapeLeft'});
      expect(devices.controller.calls, ['openLink demo://b']);
    });
  });

  group('error codes', () {
    test('a QaException code on the host comes back as the same code', () async {
      final ready = await RemoteDevices(await connect()).resolve(DeviceTarget.parse('android:Pixel_8'));
      devices.controller.failure = QaException(QaErrorCode.unsupported, 'no links here');
      await expectLater(
        ready.controller.openLink(Uri.parse('demo://x')),
        throwsA(
          isA<QaException>()
              .having((e) => e.code, 'code', QaErrorCode.unsupported)
              .having((e) => e.message, 'message', 'no links here'),
        ),
      );
    });
  });

  group('token redaction', () {
    final secret = Uri.parse('ws://127.0.0.1:7777/vm/app-1?token=s3cr3t');

    test('redactUri hides only the token', () {
      expect(redactUri(secret).toString(), 'ws://127.0.0.1:7777/vm/app-1?token=***');
      expect(redactUri(Uri.parse('ws://127.0.0.1:1/abc=/ws')).toString(), 'ws://127.0.0.1:1/abc=/ws');
    });

    test('a connect failure does not carry the token', () async {
      final failure = VmConnection.connect(
        secret,
        timeout: const Duration(milliseconds: 200),
        retryInterval: const Duration(milliseconds: 20),
        connector: (uri) async => throw WebSocketException('could not reach $uri'),
      );
      await expectLater(
        failure,
        throwsA(
          isA<LaunchException>()
              .having((e) => e.message, 'message', isNot(contains('s3cr3t')))
              .having((e) => e.message, 'message', contains('token=***')),
        ),
      );
    });

    test('a connect given up on does not carry the token', () async {
      await expectLater(
        VmConnection.connect(
          secret,
          giveUpWhen: Future.value(),
          connector: (uri) async => throw WebSocketException('could not reach $uri'),
        ),
        throwsA(isA<LaunchException>().having((e) => e.message, 'message', isNot(contains('s3cr3t')))),
      );
    });

    test('the session log does not carry the token', () async {
      final log = <String>[];
      final exit = Completer<int>();
      final launch = QaSession.launch(
        ProjectConfig(name: 'demo', source: Directory.systemTemp.path, device: 'macos'),
        log: log.add,
        devices: devices,
        launcher: FixedLauncher(
          LaunchedApp(
            appId: 'app-1',
            wsUri: secret,
            mode: 'debug',
            supportsRestart: false,
            logs: const Stream.empty(),
            exitCode: exit.future,
            onStop: () async {},
          ),
        ),
        connector: (uri) async {
          if (!exit.isCompleted) exit.complete(1);
          throw WebSocketException('could not reach $uri');
        },
      );
      Object? error;
      try {
        await launch;
      } catch (e) {
        error = e;
      }
      expect(error, isA<LaunchException>());
      expect('$error', isNot(contains('s3cr3t')));
      expect(log, contains('connecting to ws://127.0.0.1:7777/vm/app-1?token=***'));
      expect(log.join('\n'), isNot(contains('s3cr3t')));
    });
  });

  group('RemoteLauncher against a scripted host', () {
    test('a log line that arrives with the app.start response reaches the first listener', () async {
      final fake = await ScriptedHost.start((socket, r) {
        if (r.method != 'app.start') return;
        socket.add(const HostNotification('app.log', {'appId': 'app-9', 'line': 'early'}).encode());
        socket.add(HostResponse.success(r.id, {'appId': 'app-9', 'mode': 'debug', 'supportsRestart': false}).encode());
        socket.add(const HostNotification('app.log', {'appId': 'app-9', 'line': 'later'}).encode());
      });
      addTearDown(fake.close);
      final host = await RemoteHost.connect(fake.url, token);
      hosts.add(host);
      final app = await RemoteLauncher(
        host,
        fake.url,
        token,
        ProjectConfig(name: 'd', source: 'app'),
        '/p',
        'macos',
      ).start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final lines = <String>[];
      app.logs.listen(lines.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(lines, ['early', 'later']);
    });

    test('a host that goes away ends the app, its logs and pending calls', () async {
      final fake = await ScriptedHost.start((socket, r) {
        switch (r.method) {
          case 'app.start':
            socket.add(
              HostResponse.success(r.id, {'appId': 'app-1', 'mode': 'debug', 'supportsRestart': true}).encode(),
            );
          case 'app.restart':
            // Never answered: the host dies with the call in flight.
            unawaited(socket.close());
        }
      });
      addTearDown(fake.close);
      final host = await RemoteHost.connect(fake.url, token);
      hosts.add(host);
      final app = await RemoteLauncher(
        host,
        fake.url,
        token,
        ProjectConfig(name: 'd', source: 'app'),
        '/p',
        'macos',
      ).start();
      final logsDone = app.logs.drain<void>();
      await expectLater(app.restart(), throwsA(isA<RemoteHostException>()));
      expect(await app.exitCode, -1);
      await logsDone.timeout(const Duration(seconds: 5));
      await expectLater(host.call('devices.list'), throwsA(isA<RemoteHostException>()));
    });

    test('wsUri keeps the host URL base path', () async {
      final fake = await ScriptedHost.start((socket, r) {
        if (r.method == 'app.start') {
          socket.add(
            HostResponse.success(r.id, {'appId': 'app-2', 'mode': 'debug', 'supportsRestart': false}).encode(),
          );
        }
      });
      addTearDown(fake.close);
      final base = fake.url.replace(path: '/qa/');
      final host = await RemoteHost.connect(base, token);
      hosts.add(host);
      expect(fake.paths, ['/qa/control']);
      final app = await RemoteLauncher(
        host,
        base,
        token,
        ProjectConfig(name: 'd', source: 'app'),
        '/p',
        'macos',
      ).start();
      expect(app.wsUri.toString(), 'ws://127.0.0.1:${fake.url.port}/qa/vm/app-2?token=$token');
    });
  });

  group('RemoteLauncher', () {
    late Directory project;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('qa_remote');
      await Directory('${project.path}/app').create();
    });

    tearDown(() => project.delete(recursive: true));

    RemoteLauncher launcher(RemoteHost host, {String source = 'app'}) => RemoteLauncher(
      host,
      url,
      token,
      ProjectConfig(name: 'demo', source: source, device: 'macos'),
      project.path,
      'macos',
    );

    test('start returns the proxied wsUri, and logs and exit come from notifications', () async {
      final app = await launcher(await connect()).start();
      expect(app.wsUri.toString(), 'ws://127.0.0.1:${server.port}/vm/${app.appId}?token=$token');
      expect(server.launchedApps.keys, [app.appId]);
      expect((app.mode, app.supportsRestart), ('debug', true));

      final lines = <String>[];
      final logsDone = app.logs.listen(lines.add).asFuture<void>();
      apps.single.logs.add('one');
      apps.single.logs.add('two');
      apps.single.exit.complete(7);
      expect(await app.exitCode, 7);
      await logsDone;
      expect(lines, ['one', 'two']);
    });

    test('stop and restart reach the host', () async {
      final app = await launcher(await connect()).start();
      await app.restart();
      expect(apps.single.restarts, 1);
      await app.stop();
      expect(apps.single.stops, 1);
      expect(await app.exitCode, 0);
      expect(server.launchedApps, isEmpty);
    });

    test('a launch the host refuses is a LaunchException', () async {
      await expectLater(
        launcher(await connect(), source: 'missing').start(),
        throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('does not exist on the host'))),
      );
    });

    test('a lost host ends the app', () async {
      final host = await connect();
      final app = await launcher(host).start();
      await host.close();
      expect(await app.exitCode, -1);
      await app.stop(); // does not throw
    });

    test('VmConnection.connect keeps the token through the real proxy', () async {
      final vm = await FakeVmServiceServer.start();
      addTearDown(vm.close);
      appWsUri = Uri.parse('ws://127.0.0.1:${vm.port}/authcode=/ws');
      final app = await launcher(await connect()).start();
      final connection = await VmConnection.connect(app.wsUri, timeout: const Duration(seconds: 5));
      addTearDown(connection.dispose);
      final pong = await connection.call(QaMethod.ping, {});
      expect(pong.result, {'platform': 'macOS'});
      expect(vm.paths, ['/authcode=/ws']);
    });
  });
}

class FixedLauncher implements AppLauncher {
  FixedLauncher(this.app);
  final LaunchedApp app;

  @override
  Future<LaunchedApp> start() async => app;
}

/// A host that answers `hello` itself and hands every other request to a
/// script, which answers (or does not) as the test needs.
class ScriptedHost {
  ScriptedHost._(this._server, void Function(WebSocket socket, HostRequest request) script) {
    _server.listen((request) async {
      paths.add(request.uri.path);
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((frame) {
        final r = HostMessage.decode(frame as String) as HostRequest;
        if (r.method == 'hello') {
          socket.add(
            HostResponse.success(r.id, {
              'protocol': hostProtocolVersion,
              'os': 'windows',
              'osVersion': '10.0',
              'qaVersion': qaVersion,
            }).encode(),
          );
        } else {
          script(socket, r);
        }
      });
    });
  }

  static Future<ScriptedHost> start(void Function(WebSocket socket, HostRequest request) script) async =>
      ScriptedHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), script);

  final HttpServer _server;
  final paths = <String>[];

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);
}

class RecordingTransport implements QaTransport {
  /// The (width, height) of the view each ping reports, in turn; the last
  /// one repeats.
  RecordingTransport({this.views = const []});

  final List<(double, double)> views;
  final calls = <(QaMethod, Map<String, Object?>)>[];
  var _pings = 0;

  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) async {
    calls.add((method, args));
    if (method == QaMethod.ping && views.isNotEmpty) {
      final (width, height) = views[min(_pings++, views.length - 1)];
      return QaResponse.success({
        'views': [
          {'viewId': 0, 'width': width, 'height': height, 'devicePixelRatio': 2.6},
        ],
      });
    }
    return QaResponse.success(method == QaMethod.waitForIdle ? const {'settled': 'idle'} : const {});
  }
}

/// Just enough of a Dart VM service for [VmConnection]: stream listens, one
/// isolate exposing ext.qa.ping, and that extension answering.
class FakeVmServiceServer {
  FakeVmServiceServer._(this._server) {
    _server.listen((request) async {
      paths.add(request.uri.path);
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((frame) {
        final r = jsonDecode(frame as String) as Map<String, Object?>;
        socket.add(jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': _answer(r['method']! as String)}));
      });
    });
  }

  static Future<FakeVmServiceServer> start() async =>
      FakeVmServiceServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final paths = <String>[];

  int get port => _server.port;

  static const _isolate = {'type': '@Isolate', 'id': 'isolates/1', 'name': 'main', 'number': '1'};

  Map<String, Object?> _answer(String method) => switch (method) {
    'streamListen' => {'type': 'Success'},
    'getVM' => {
      'type': 'VM',
      'name': 'vm',
      'isolates': [_isolate],
    },
    'getIsolate' => {
      ..._isolate,
      'type': 'Isolate',
      'extensionRPCs': [QaMethod.ping.extensionName],
    },
    _ => {
      'type': '_extensionType',
      'method': method,
      ...QaResponse.success({'platform': 'macOS'}).toJson(),
    },
  };

  Future<void> close() => _server.close(force: true);
}
