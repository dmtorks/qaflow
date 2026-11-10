import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../driver/qa_driver.dart';
import '../launch/launched_app.dart';
import '../launch/process.dart';
import 'android_sdk.dart';
import 'device.dart';
import 'device_manager.dart';

/// Android emulators through the SDK's `emulator` and `adb`.
class AndroidDevices implements MobileDevices {
  AndroidDevices({
    AndroidSdk? sdk,
    ProcessRunner? run,
    ProcessStarter? start,
    DetachedStarter? startDetached,
    Duration? bootTimeout,
    this.simSettleTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(seconds: 1),
    Map<String, String>? environment,
  }) : sdk = sdk ?? AndroidSdk.locate(environment: environment),
       _run = run ?? defaultProcessRunner,
       _startProcess = start ?? defaultProcessStarter,
       _start = startDetached ?? defaultDetachedStarter,
       bootTimeout = bootTimeout ?? defaultBootTimeout(environment ?? Platform.environment);

  final AndroidSdk sdk;
  final ProcessRunner _run;
  final ProcessStarter _startProcess;
  final DetachedStarter _start;
  final Duration bootTimeout;

  /// How long a fresh boot waits for the SIM operator (mcc/mnc) to reach the
  /// configuration; an emulator without a SIM is used once this passes.
  final Duration simSettleTimeout;
  final Duration pollInterval;

  static final RegExp serialPattern = RegExp(r'^emulator-\d+$');
  static const String _noSdk = 'Android SDK not found (set ANDROID_HOME)';

  /// 180 s, or QA_ANDROID_BOOT_TIMEOUT seconds (a cold boot on CI is slow).
  static Duration defaultBootTimeout(Map<String, String> environment) {
    final seconds = int.tryParse(environment['QA_ANDROID_BOOT_TIMEOUT'] ?? '');
    return Duration(seconds: seconds != null && seconds > 0 ? seconds : 180);
  }

  Future<ProcessResult> _adb(List<String> args) => _run(sdk.adb, args);

  static List<String> _lines(Object? out) => [
    for (final l in const LineSplitter().convert(out.toString()))
      if (l.trim().isNotEmpty) l.trim(),
  ];

  Future<List<String>> _avds() async {
    final r = await _run(sdk.emulator, ['-list-avds']);
    if (r.exitCode != 0) throw DeviceToolException('emulator -list-avds failed: ${r.stderr.toString().trim()}');
    return [
      for (final l in _lines(r.stdout))
        if (!l.startsWith('INFO') && !l.startsWith('WARNING')) l,
    ];
  }

  Future<List<String>> _runningSerials() async {
    final r = await _adb(['devices']);
    if (r.exitCode != 0) throw DeviceToolException('adb devices failed: ${r.stderr.toString().trim()}');
    return [
      for (final l in _lines(r.stdout))
        if (l.split(RegExp(r'\s+')) case [final serial, 'device'] when serialPattern.hasMatch(serial)) serial,
    ];
  }

  Future<String?> _avdName(String serial) async {
    final r = await _adb(['-s', serial, 'emu', 'avd', 'name']);
    if (r.exitCode != 0) return null;
    return _lines(r.stdout).where((l) => l != 'OK').firstOrNull;
  }

  Future<String?> _osVersion(String serial) async {
    final release = _lines((await _adb(['-s', serial, 'shell', 'getprop', 'ro.build.version.release'])).stdout);
    final api = _lines((await _adb(['-s', serial, 'shell', 'getprop', 'ro.build.version.sdk'])).stdout);
    if (release.isEmpty || api.isEmpty) return null;
    return 'Android ${release.first} (API ${api.first})';
  }

  @override
  Future<List<DeviceInfo>> list() async {
    try {
      final avds = await _avds();
      final running = {for (final s in await _runningSerials()) s: await _avdName(s)};
      final devices = <DeviceInfo>[];
      for (final avd in avds) {
        final serial = running.entries.where((e) => e.value == avd).firstOrNull?.key;
        devices.add(
          DeviceInfo(
            platform: DevicePlatform.android,
            name: avd,
            id: avd,
            osVersion: serial == null ? null : await _osVersion(serial),
            booted: serial != null,
          ),
        );
      }
      for (final MapEntry(key: serial, value: name) in running.entries) {
        if (name != null && avds.contains(name)) continue;
        devices.add(
          DeviceInfo(
            platform: DevicePlatform.android,
            name: name ?? serial,
            id: serial,
            osVersion: await _osVersion(serial),
          ),
        );
      }
      return devices;
    } on ProcessException {
      throw DeviceToolException(_noSdk);
    }
  }

  @override
  Future<ReadyDevice> resolve(String query, {void Function(DeviceInfo device)? onBooting, CancelSignal? cancel}) async {
    try {
      return await _resolve(query, onBooting, cancel);
    } on ProcessException {
      throw LaunchException(_noSdk);
    } on DeviceToolException catch (e) {
      throw LaunchException(e.message);
    }
  }

  Future<ReadyDevice> _resolve(String query, void Function(DeviceInfo device)? onBooting, CancelSignal? cancel) async {
    final serials = await _runningSerials();
    if (serialPattern.hasMatch(query)) {
      if (!serials.contains(query)) throw LaunchException('$query is not running');
      return _ready(query, await _avdName(query) ?? query, bootedByUs: false);
    }
    for (final s in serials) {
      if (await _avdName(s) == query) return _ready(s, query, bootedByUs: false);
    }
    final avds = await _avds();
    if (!avds.contains(query)) {
      final available = avds.isEmpty ? 'none' : avds.take(5).join(', ');
      throw LaunchException('no Android emulator (AVD) named "$query"; available: $available');
    }
    onBooting?.call(DeviceInfo(platform: DevicePlatform.android, name: query, id: query, booted: false));
    await _start(sdk.emulator, ['-avd', query, '-no-snapshot-save', '-no-boot-anim']);
    var abandoned = false;
    final stop = Completer<void>();
    final serial =
        await guardDeviceWait(
          _waitForBoot(query, serials.toSet(), () => abandoned || (cancel?.isCancelled ?? false), stop.future),
          timeout: bootTimeout,
          what: 'booting $query',
          cancel: cancel,
        ).whenComplete(() {
          abandoned = true;
          stop.complete();
        });
    return _ready(serial, query, bootedByUs: true);
  }

  /// Polls until a new emulator reports [avd] and has finished booting.
  /// Stops polling once [abandoned] says the caller gave up.
  Future<String> _waitForBoot(String avd, Set<String> before, bool Function() abandoned, Future<void> stop) async {
    String? serial;
    while (serial == null) {
      if (abandoned()) return '';
      for (final s in await _runningSerials()) {
        if (!before.contains(s) && await _avdName(s) == avd) serial = s;
      }
      if (serial == null) await Future<void>.delayed(pollInterval);
    }
    await runUntil(_startProcess, sdk.adb, ['-s', serial, 'wait-for-device'], stop: stop);
    while (!abandoned()) {
      final r = await _adb(['-s', serial, 'shell', 'getprop', 'sys.boot_completed']);
      if (r.stdout.toString().trim() == '1') break;
      await Future<void>.delayed(pollInterval);
    }
    // The SIM loads seconds after sys.boot_completed. Its mcc/mnc change
    // relaunches the foreground activity, which replaces the Flutter engine
    // under qa if the app is already running by then.
    final settle = Stopwatch()..start();
    while (!abandoned() && settle.elapsed < simSettleTimeout) {
      final r = await _adb(['-s', serial, 'shell', 'am', 'get-config']);
      if (RegExp(r'^config: mcc\d', multiLine: true).hasMatch(r.stdout.toString())) break;
      await Future<void>.delayed(pollInterval);
    }
    // Wakes the screen and dismisses the lock screen.
    await _adb(['-s', serial, 'shell', 'input', 'keyevent', '82']);
    return serial;
  }

  Future<ReadyDevice> _ready(String serial, String name, {required bool bootedByUs}) async => ReadyDevice(
    flutterId: serial,
    info: DeviceInfo(platform: DevicePlatform.android, name: name, id: serial, osVersion: await _osVersion(serial)),
    bootedByUs: bootedByUs,
    controller: AndroidDeviceController(serial, sdk: sdk, run: _run),
  );
}

class AndroidDeviceController implements DeviceController {
  AndroidDeviceController(
    this.serial, {
    required this.sdk,
    ProcessRunner? run,
    this.rotationTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 100),
  }) : _run = run ?? defaultProcessRunner;

  final String serial;
  final AndroidSdk sdk;
  final ProcessRunner _run;
  final Duration rotationTimeout;
  final Duration pollInterval;

  static const Map<ScreenOrientation, int> _rotation = {
    ScreenOrientation.portrait: 0,
    ScreenOrientation.landscapeLeft: 1,
    ScreenOrientation.landscapeRight: 3,
  };

  Future<ProcessResult> _shell(List<String> args) => _run(sdk.adb, ['-s', serial, 'shell', ...args]);

  @override
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver) async {
    await applyOrientation(orientation);
    await waitForViews(orientation, driver, timeout: rotationTimeout, pollInterval: pollInterval);
  }

  /// The device half of [setOrientation]: the adb settings alone. A QA host
  /// runs only this, since the app's agent is reachable from the client.
  Future<void> applyOrientation(ScreenOrientation orientation) async {
    await _put('accelerometer_rotation', 0, 'setOrientation');
    await _put('user_rotation', _rotation[orientation]!, 'setOrientation');
  }

  /// The app half of [setOrientation]. The setting applies asynchronously:
  /// wait for the app's view to take the new shape, so the next step (a
  /// screenshot, the studio's mirror) sees it. An app locked to one
  /// orientation never rotates; that is not a failure.
  static Future<void> waitForViews(
    ScreenOrientation orientation,
    QaDriver driver, {
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    final landscape = orientation != ScreenOrientation.portrait;
    final waited = Stopwatch()..start();
    while (waited.elapsed < timeout) {
      final views = ((await driver.ping()).result?['views'] as List?) ?? const [];
      final view = views.isEmpty ? const <String, Object?>{} : (views.first as Map).cast<String, Object?>();
      final width = (view['width'] as num?)?.toDouble() ?? 0;
      final height = (view['height'] as num?)?.toDouble() ?? 0;
      if (width > 0 && height > 0 && (width > height) == landscape) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Leaves accelerometer_rotation at 0, as setOrientation does on a restore
  /// with the app running: auto-rotate stays off so the next run starts in
  /// portrait whatever the emulator's virtual sensors say.
  @override
  Future<void> resetOrientation() async {
    await _put('user_rotation', 0, 'resetOrientation');
  }

  Future<void> _put(String setting, int value, String what) async {
    final r = await _shell(['settings', 'put', 'system', setting, '$value']);
    if (r.exitCode != 0) throw QaException(QaErrorCode.internal, '$what failed: ${r.stderr.toString().trim()}');
  }

  @override
  Future<void> openLink(Uri link) async {
    // adb joins its arguments into one device shell command line.
    final quoted = "'${link.toString().replaceAll("'", r"'\''")}'";
    final r = await _shell(['am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', quoted]);
    final error = const LineSplitter()
        .convert('${r.stdout}\n${r.stderr}')
        .where((l) => l.startsWith('Error'))
        .firstOrNull;
    if (r.exitCode != 0 || error != null) {
      throw QaException(QaErrorCode.internal, 'openLink $link failed: ${(error ?? r.stderr.toString()).trim()}');
    }
  }
}
