import 'dart:async';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

class FakeApp {
  /// Like the real launchers, the logs end when the app exits.
  FakeApp([Uri? wsUri]) : wsUri = wsUri ?? Uri.parse('ws://127.0.0.1:1/authcode=/ws') {
    unawaited(exit.future.whenComplete(logs.close));
  }

  final logs = StreamController<String>.broadcast();
  final exit = Completer<int>();
  final Uri wsUri;
  var stops = 0;
  var restarts = 0;

  LaunchedApp get app => LaunchedApp(
    appId: 'daemon-app',
    wsUri: wsUri,
    mode: 'debug',
    supportsRestart: true,
    logs: logs.stream,
    exitCode: exit.future,
    onStop: () async {
      stops++;
      if (!exit.isCompleted) exit.complete(0);
    },
    onRestart: () async => restarts++,
  );
}

class FakeLauncher implements AppLauncher {
  FakeLauncher(this._make);
  final FakeApp Function() _make;

  @override
  Future<LaunchedApp> start() async => _make().app;
}

class FakeController implements DeviceController {
  final calls = <String>[];

  @override
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver) async =>
      calls.add('setOrientation ${orientation.name}');

  @override
  Future<void> resetOrientation() async => calls.add('resetOrientation');

  /// Thrown by [openLink] when set.
  QaException? failure;

  @override
  Future<void> openLink(Uri link) async {
    if (failure case final e?) throw e;
    calls.add('openLink $link');
  }
}

class FakeDevices implements Devices {
  final controller = FakeController();

  /// When set, the Android device resolves with this controller instead.
  DeviceController? androidController;
  final resolved = <DeviceTarget>[];
  Exception? failResolve;

  /// When set, resolve waits for it, like a device that is still booting.
  Completer<void>? resolveGate;

  static const pixel = DeviceInfo(
    platform: DevicePlatform.android,
    name: 'Pixel 8',
    id: 'Pixel_8',
    osVersion: 'Android 14 (API 34)',
    booted: false,
  );

  static const iphone = DeviceInfo(
    platform: DevicePlatform.ios,
    name: 'iPhone 17',
    id: 'UDID-1',
    osVersion: 'iOS 26.0',
  );

  @override
  Future<DeviceList> list() async => const DeviceList(
    [DeviceInfo(platform: DevicePlatform.macos, name: 'macOS', id: 'macos', osVersion: '27.0'), pixel],
    [DeviceGroupProblem(DevicePlatform.ios, 'no xcrun')],
  );

  @override
  Future<ReadyDevice> resolve(
    DeviceTarget target, {
    void Function(DeviceInfo device)? onBooting,
    CancelSignal? cancel,
  }) async {
    if (failResolve case final e?) throw e;
    await resolveGate?.future;
    resolved.add(target);
    if (target.platform == DevicePlatform.ios) {
      return ReadyDevice(flutterId: 'UDID-1', info: iphone, controller: controller);
    }
    onBooting?.call(pixel);
    return ReadyDevice(
      flutterId: 'emulator-5554',
      info: pixel.copyWith(booted: true),
      controller: androidController ?? controller,
    );
  }
}
