import 'dart:async';
import 'dart:io';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../driver/qa_driver.dart';
import '../launch/launched_app.dart';

enum DevicePlatform {
  macos('macOS'),
  windows('Windows'),
  linux('Linux'),
  flutterTester('flutter-tester'),
  ios('iOS'),
  android('Android');

  const DevicePlatform(this.label);

  /// As people write it, and as the agent's `ping` reports it (case aside).
  final String label;

  bool get isMobile => this == ios || this == android;
}

/// A `device:` value from the project file or `--device`.
class DeviceTarget {
  const DeviceTarget(this.platform, [this.query]);

  final DevicePlatform platform;

  /// Simulator name or UDID, AVD name or emulator serial; null on desktop.
  final String? query;

  static const Map<String, DevicePlatform> desktopNames = {
    'macos': DevicePlatform.macos,
    'windows': DevicePlatform.windows,
    'linux': DevicePlatform.linux,
    'flutter-tester': DevicePlatform.flutterTester,
  };

  static DeviceTarget parse(String value) {
    final v = value.trim();
    final desktop = desktopNames[v];
    if (desktop != null) return DeviceTarget(desktop);
    final colon = v.indexOf(':');
    final prefix = colon < 0 ? '' : v.substring(0, colon);
    final query = colon < 0 ? '' : v.substring(colon + 1).trim();
    switch (prefix) {
      case 'ios':
        if (query.isEmpty) {
          throw const FormatException('ios: needs a simulator name or UDID, e.g. "ios:iPhone 17 Pro"');
        }
        return DeviceTarget(DevicePlatform.ios, query);
      case 'android':
        if (query.isEmpty) {
          throw const FormatException('android: needs an AVD name or emulator serial, e.g. "android:emulator-5554"');
        }
        return DeviceTarget(DevicePlatform.android, query);
    }
    throw FormatException(
      'unknown device "$v"; use macos, windows, linux, flutter-tester, '
      'ios:<simulator name or UDID> or android:<AVD name or emulator serial>'
      '${colon < 0 && v.isNotEmpty ? ' (e.g. "ios:$v")' : ''}',
    );
  }

  @override
  String toString() => switch (platform) {
    DevicePlatform.ios => 'ios:$query',
    DevicePlatform.android => 'android:$query',
    _ => desktopNames.entries.firstWhere((e) => e.value == platform).key,
  };
}

class DeviceInfo {
  const DeviceInfo({required this.platform, required this.name, required this.id, this.osVersion, this.booted = true});

  factory DeviceInfo.fromJson(Map<String, Object?> json) => DeviceInfo(
    platform: DevicePlatform.values.byName(json['platform'] as String),
    name: json['name'] as String,
    id: json['id'] as String,
    osVersion: json['osVersion'] as String?,
  );

  /// The host or `flutter-tester`: always available, never booted. The host
  /// carries its OS version ([hostVersion] of [hostOsVersion], by default
  /// `Platform.operatingSystemVersion`), since an OS upgrade can change how
  /// the app renders; `flutter-tester` has none.
  factory DeviceInfo.desktop(DevicePlatform platform, {String? hostOsVersion}) => DeviceInfo(
    platform: platform,
    name: platform.label,
    id: DeviceTarget.desktopNames.entries.firstWhere((e) => e.value == platform).key,
    osVersion: platform == DevicePlatform.flutterTester
        ? null
        : hostVersion(hostOsVersion ?? Platform.operatingSystemVersion),
  );

  /// `major.minor` from an OS version string such as macOS's
  /// `Version 27.0.1 (Build 26A434)`, Linux's `6.5.0-14-generic ...` or
  /// Windows's `"Windows 10 Pro" 10.0 (Build 19045)`; null when there is none.
  static String? hostVersion(String raw) {
    final m = RegExp(r'(\d+)\.(\d+)').firstMatch(raw);
    return m == null ? null : '${m[1]}.${m[2]}';
  }

  final DevicePlatform platform;
  final String name;

  /// UDID, AVD name or emulator serial; the device string's name on desktop.
  final String id;

  /// e.g. `iOS 26.5` or `Android 14 (API 34)`.
  final String? osVersion;
  final bool booted;

  String get title => osVersion == null ? name : '$name ($osVersion)';

  /// The folder name for this device's screenshot baselines: platform, name
  /// and OS version, filename-safe. Desktop devices use the platform name and
  /// the host OS version (`macos-27.0`). [suffix] keeps separate sets, e.g.
  /// for CI.
  String baselineKey({String? suffix}) {
    String clean(String part) => part.replaceAll(RegExp(r'[^A-Za-z0-9.]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final desktop = platform != DevicePlatform.ios && platform != DevicePlatform.android;
    final hasVersion = osVersion != null && clean(osVersion!).isNotEmpty;
    final base = desktop
        ? [
            DeviceTarget.desktopNames.entries.firstWhere((e) => e.value == platform).key,
            if (hasVersion) clean(osVersion!),
          ].join('-')
        : [
            platform.name,
            if (clean(name).isNotEmpty) clean(name) else clean(id),
            if (hasVersion) clean(osVersion!),
          ].join('-');
    final cleanSuffix = suffix == null ? '' : clean(suffix).replaceAll(RegExp(r'^[._]+|[._]+$'), '');
    return cleanSuffix.isEmpty ? base : '$base-$cleanSuffix';
  }

  DeviceInfo copyWith({bool? booted, String? osVersion}) => DeviceInfo(
    platform: platform,
    name: name,
    id: id,
    osVersion: osVersion ?? this.osVersion,
    booted: booted ?? this.booted,
  );

  Map<String, Object?> toJson() => {
    'platform': platform.name,
    'name': name,
    'id': id,
    if (osVersion != null) 'osVersion': osVersion,
  };
}

enum ScreenOrientation { portrait, landscapeLeft, landscapeRight }

/// Device-level actions a flow can ask for, beyond what the agent does in-app.
abstract class DeviceController {
  /// [driver] is the session's current driver; iOS rotates through the agent.
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver);

  /// Puts the device back in portrait when the app is not running. Only
  /// Android needs it: a rotation there is a device setting that outlives
  /// the app.
  Future<void> resetOrientation();

  Future<void> openLink(Uri link);
}

class UnsupportedDeviceController implements DeviceController {
  const UnsupportedDeviceController(this.platform);
  final DevicePlatform platform;

  Never _unsupported(String what) => throw QaException(
    QaErrorCode.unsupported,
    '$what needs an iOS simulator or Android emulator, not ${platform.label}',
  );

  @override
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver) async => _unsupported('setOrientation');

  @override
  Future<void> resetOrientation() async {}

  @override
  Future<void> openLink(Uri link) async => _unsupported('openLink');
}

class ReadyDevice {
  const ReadyDevice({required this.flutterId, required this.info, required this.controller, this.bootedByUs = false});

  /// What `flutter run -d` takes.
  final String flutterId;
  final DeviceInfo info;
  final DeviceController controller;
  final bool bootedByUs;
}

/// Why a whole platform's devices could not be listed (a missing toolchain).
class DeviceGroupProblem {
  const DeviceGroupProblem(this.platform, this.message);
  final DevicePlatform platform;
  final String message;
}

class DeviceList {
  const DeviceList(this.devices, this.problems);
  final List<DeviceInfo> devices;
  final List<DeviceGroupProblem> problems;
}

/// A device tool (`xcrun`, `adb`, `emulator`) is missing or failed to list.
class DeviceToolException implements Exception {
  DeviceToolException(this.message);
  final String message;
  @override
  String toString() => 'DeviceToolException: $message';
}

class CancelSignal {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get future => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// [work] bounded by [timeout] and ended early by [cancel]. The timer is
/// cancelled on completion so a CLI run does not linger for it.
Future<T> guardDeviceWait<T>(Future<T> work, {required Duration timeout, required String what, CancelSignal? cancel}) {
  final done = Completer<T>();
  void fail(Object error, [StackTrace? stack]) {
    if (!done.isCompleted) done.completeError(error, stack);
  }

  final timer = Timer(timeout, () => fail(LaunchException('$what did not finish within ${timeout.inSeconds} s')));
  cancel?.future.then((_) => fail(LaunchException('stopped while waiting for $what')));
  work.then((value) {
    if (!done.isCompleted) done.complete(value);
  }, onError: fail);
  return done.future.whenComplete(timer.cancel);
}
