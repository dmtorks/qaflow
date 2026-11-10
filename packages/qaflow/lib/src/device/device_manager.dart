import 'dart:io';

import '../launch/launched_app.dart';
import 'android_devices.dart';
import 'device.dart';
import 'ios_devices.dart';

/// One mobile platform's simulators or emulators.
abstract interface class MobileDevices {
  Future<List<DeviceInfo>> list();

  Future<ReadyDevice> resolve(String query, {void Function(DeviceInfo device)? onBooting, CancelSignal? cancel});
}

/// Lists the devices flows can run on and turns a [DeviceTarget] into a
/// booted, ready device; local or on a remote host.
abstract interface class Devices {
  Future<DeviceList> list();

  Future<ReadyDevice> resolve(DeviceTarget target, {void Function(DeviceInfo device)? onBooting, CancelSignal? cancel});
}

/// Lists every device this host can run flows on, and turns a
/// [DeviceTarget] into a booted, ready device.
class DeviceManager implements Devices {
  DeviceManager({MobileDevices? ios, MobileDevices? android, bool? isMacOS, DevicePlatform? host, this.hostOsVersion})
    : _ios = ios ?? IosDevices(),
      _android = android ?? AndroidDevices(),
      _isMacOS = isMacOS ?? Platform.isMacOS,
      _host = host ?? DeviceTarget.parse(_hostName()).platform;

  final MobileDevices _ios;
  final MobileDevices _android;
  final bool _isMacOS;
  final DevicePlatform _host;

  /// `Platform.operatingSystemVersion` when null; see [DeviceInfo.desktop].
  final String? hostOsVersion;

  static String _hostName() => Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
      ? 'windows'
      : 'linux';

  static const String _iosNeedsMac = 'iOS simulators need macOS';

  @override
  Future<DeviceList> list() async {
    final devices = [
      DeviceInfo.desktop(_host, hostOsVersion: hostOsVersion),
      DeviceInfo.desktop(DevicePlatform.flutterTester),
    ];
    final problems = <DeviceGroupProblem>[];
    Future<void> add(DevicePlatform platform, MobileDevices source, String? unavailable) async {
      if (unavailable != null) {
        problems.add(DeviceGroupProblem(platform, unavailable));
        return;
      }
      try {
        devices.addAll(await source.list());
      } on DeviceToolException catch (e) {
        problems.add(DeviceGroupProblem(platform, e.message));
      }
    }

    await add(DevicePlatform.ios, _ios, _isMacOS ? null : _iosNeedsMac);
    await add(DevicePlatform.android, _android, null);
    return DeviceList(devices, problems);
  }

  @override
  Future<ReadyDevice> resolve(
    DeviceTarget target, {
    void Function(DeviceInfo device)? onBooting,
    CancelSignal? cancel,
  }) async {
    switch (target.platform) {
      case DevicePlatform.ios:
        if (!_isMacOS) throw LaunchException(_iosNeedsMac);
        return _ios.resolve(target.query!, onBooting: onBooting, cancel: cancel);
      case DevicePlatform.android:
        return _android.resolve(target.query!, onBooting: onBooting, cancel: cancel);
      case DevicePlatform.macos || DevicePlatform.windows || DevicePlatform.linux || DevicePlatform.flutterTester:
        return ReadyDevice(
          flutterId: target.toString(),
          info: DeviceInfo.desktop(target.platform, hostOsVersion: hostOsVersion),
          controller: UnsupportedDeviceController(target.platform),
        );
    }
  }
}
