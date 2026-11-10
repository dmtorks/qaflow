import 'dart:async';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../device/android_devices.dart';
import '../device/device.dart';
import '../device/device_manager.dart';
import '../device/ios_devices.dart';
import '../driver/qa_driver.dart';
import '../launch/launched_app.dart';
import 'host_protocol.dart';
import 'remote_host.dart';

/// The devices of a QA host. Their [DeviceInfo] values are the host's, so
/// baseline keys carry the host's OS version.
class RemoteDevices implements Devices {
  RemoteDevices(this.host);

  final RemoteHost host;

  @override
  Future<DeviceList> list() async {
    final result = await host.launchCall('devices.list');
    return DeviceList(
      [for (final d in result['devices']! as List) deviceInfoFromWire((d as Map).cast())],
      [
        for (final problem in result['problems']! as List)
          DeviceGroupProblem(
            DevicePlatform.values.byName((problem as Map)['platform'] as String),
            problem['message'] as String,
          ),
      ],
    );
  }

  /// [cancel] stops waiting here; a boot the host has begun carries on there.
  @override
  Future<ReadyDevice> resolve(
    DeviceTarget target, {
    void Function(DeviceInfo device)? onBooting,
    CancelSignal? cancel,
  }) async {
    final booting = host
        .on('devices.booting')
        .listen((n) => onBooting?.call(deviceInfoFromWire((n.params['info']! as Map).cast())));
    try {
      final call = host.launchCall('devices.resolve', {'device': target.toString()});
      final result = await (cancel == null
          ? call
          : Future.any([
              call,
              cancel.future.then<Map<String, Object?>>(
                (_) => throw LaunchException('stopped while waiting for $target on the QA host'),
              ),
            ]));
      final info = deviceInfoFromWire((result['info']! as Map).cast());
      final flutterId = result['flutterId']! as String;
      return ReadyDevice(flutterId: flutterId, info: info, controller: RemoteDeviceController(host, flutterId, info));
    } finally {
      await booting.cancel();
    }
  }
}

/// A host's device. iOS rotates through the agent, exactly as
/// [IosDeviceController] does locally; everything else is a `device.*` call.
/// Android's rotation is split: the host runs adb, then this client waits for
/// the app's views through its own driver, as [AndroidDeviceController] does.
class RemoteDeviceController implements DeviceController {
  RemoteDeviceController(
    this.host,
    this.flutterId,
    this.info, {
    this.rotationTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 100),
  });

  final RemoteHost host;
  final String flutterId;
  final DeviceInfo info;
  final Duration rotationTimeout;
  final Duration pollInterval;

  bool get _ios => info.platform == DevicePlatform.ios;

  @override
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver) async {
    if (_ios) return IosDeviceController.rotateThroughAgent(orientation, driver);
    await _deviceCall('device.setOrientation', {'flutterId': flutterId, 'orientation': orientation.name});
    if (info.platform == DevicePlatform.android) {
      await AndroidDeviceController.waitForViews(
        orientation,
        driver,
        timeout: rotationTimeout,
        pollInterval: pollInterval,
      );
    }
  }

  @override
  Future<void> resetOrientation() async {
    // As locally: the preferred orientation dies with the app.
    if (_ios) return;
    await _deviceCall('device.resetOrientation', {'flutterId': flutterId});
  }

  @override
  Future<void> openLink(Uri link) => _deviceCall('device.openLink', {'flutterId': flutterId, 'link': '$link'});

  /// Failures surface as [QaException], as the local controllers' do.
  Future<void> _deviceCall(String method, Map<String, Object?> params) async {
    try {
      await host.call(method, params);
    } on HostError catch (e) {
      throw QaException(e.qaCode, e.message);
    } on RemoteHostException catch (e) {
      throw QaException(QaErrorCode.internal, e.message);
    }
  }
}
