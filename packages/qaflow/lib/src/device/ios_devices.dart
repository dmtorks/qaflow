import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../driver/qa_driver.dart';
import '../launch/launched_app.dart';
import '../launch/process.dart';
import 'device.dart';
import 'device_manager.dart';

/// iOS simulators through `xcrun simctl`.
class IosDevices implements MobileDevices {
  IosDevices({ProcessRunner? run, ProcessStarter? start, Duration? bootTimeout, Map<String, String>? environment})
    : _run = run ?? defaultProcessRunner,
      _start = start ?? defaultProcessStarter,
      bootTimeout = bootTimeout ?? defaultBootTimeout(environment ?? Platform.environment);

  final ProcessRunner _run;
  final ProcessStarter _start;
  final Duration bootTimeout;

  /// 120 s, or QA_IOS_BOOT_TIMEOUT seconds (a cold boot on CI is slow).
  static Duration defaultBootTimeout(Map<String, String> environment) {
    final seconds = int.tryParse(environment['QA_IOS_BOOT_TIMEOUT'] ?? '');
    return Duration(seconds: seconds != null && seconds > 0 ? seconds : 120);
  }

  static final RegExp _runtime = RegExp(r'SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?$');

  /// Every available iOS simulator, newest runtime first.
  @override
  Future<List<DeviceInfo>> list() async {
    final ProcessResult r;
    try {
      r = await _run('xcrun', ['simctl', 'list', 'devices', 'available', '-j']);
    } on ProcessException {
      throw DeviceToolException('Xcode command line tools not found (xcrun)');
    }
    if (r.exitCode != 0) throw DeviceToolException('xcrun simctl failed: ${r.stderr.toString().trim()}');
    final devices = (jsonDecode(r.stdout as String) as Map)['devices'] as Map;
    final runtimes = <(List<int>, String, List<Object?>)>[];
    for (final entry in devices.entries) {
      final m = _runtime.firstMatch(entry.key as String);
      if (m == null) continue;
      final version = [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3] ?? '0')];
      final label = 'iOS ${m[1]}.${m[2]}${m[3] == null ? '' : '.${m[3]}'}';
      runtimes.add((version, label, entry.value as List<Object?>));
    }
    runtimes.sort((a, b) {
      for (var i = 0; i < 3; i++) {
        final c = b.$1[i].compareTo(a.$1[i]);
        if (c != 0) return c;
      }
      return 0;
    });
    return [
      for (final (_, label, list) in runtimes)
        for (final d in list.cast<Map<Object?, Object?>>())
          if (d['isAvailable'] != false)
            DeviceInfo(
              platform: DevicePlatform.ios,
              name: d['name'] as String,
              id: d['udid'] as String,
              osVersion: label,
              booted: d['state'] == 'Booted',
            ),
    ];
  }

  /// Finds [query] by UDID, then by name (newest runtime wins), boots it if
  /// needed and waits until it has finished booting.
  @override
  Future<ReadyDevice> resolve(String query, {void Function(DeviceInfo device)? onBooting, CancelSignal? cancel}) async {
    final List<DeviceInfo> all;
    try {
      all = await list();
    } on DeviceToolException catch (e) {
      throw LaunchException(e.message);
    }
    final q = query.toLowerCase();
    final match =
        all.where((d) => d.id.toLowerCase() == q).firstOrNull ?? all.where((d) => d.name == query).firstOrNull;
    if (match == null) {
      final names = <String>{for (final d in all) d.name}.take(5).join(', ');
      throw LaunchException('no iOS simulator named "$query"; available: $names');
    }
    if (!match.booted) {
      onBooting?.call(match);
      final boot = await _run('xcrun', ['simctl', 'boot', match.id]);
      if (boot.exitCode != 0 && !boot.stderr.toString().contains('current state: Booted')) {
        throw LaunchException('could not boot ${match.title}: ${boot.stderr.toString().trim()}');
      }
      final abandoned = Completer<void>();
      final status = await guardDeviceWait(
        runUntil(_start, 'xcrun', ['simctl', 'bootstatus', match.id, '-b'], stop: abandoned.future),
        timeout: bootTimeout,
        what: 'booting ${match.title}',
        cancel: cancel,
      ).whenComplete(abandoned.complete);
      if (status.exitCode != 0) {
        throw LaunchException('${match.title} did not finish booting: ${status.stderr.toString().trim()}');
      }
    }
    // Shows the simulator window for anyone watching; frames do not need it.
    await _run('open', ['-a', 'Simulator']);
    return ReadyDevice(
      flutterId: match.id,
      info: match.copyWith(booted: true),
      bootedByUs: !match.booted,
      controller: IosDeviceController(match.id, run: _run),
    );
  }
}

class IosDeviceController implements DeviceController {
  IosDeviceController(this.udid, {ProcessRunner? run}) : _run = run ?? defaultProcessRunner;

  final String udid;
  final ProcessRunner _run;

  /// simctl cannot rotate a simulator; the agent sets the app's preferred
  /// orientation instead (spec 4.3). Shared with the remote controller,
  /// which drives a host's simulator the same way.
  static Future<void> rotateThroughAgent(ScreenOrientation orientation, QaDriver driver) =>
      driver.setOrientation(orientation.name);

  @override
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver) =>
      rotateThroughAgent(orientation, driver);

  /// The preferred orientation dies with the app; the simulator never rotated.
  @override
  Future<void> resetOrientation() async {}

  @override
  Future<void> openLink(Uri link) async {
    final r = await _run('xcrun', ['simctl', 'openurl', udid, link.toString()]);
    if (r.exitCode != 0) {
      throw QaException(QaErrorCode.internal, 'openLink $link failed: ${r.stderr.toString().trim()}');
    }
  }
}
