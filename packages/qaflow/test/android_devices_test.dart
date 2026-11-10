import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'fake_process.dart';
import 'flow_test_support.dart';

const adb = '/sdk/platform-tools/adb';
const emulator = '/sdk/emulator/emulator';
const header = 'List of devices attached\n';

void main() {
  late FakeRunner run;
  late FakeDetachedStarter start;
  late FakeStarter waits;
  late AndroidDevices android;

  setUp(() {
    run = FakeRunner();
    start = FakeDetachedStarter();
    waits = FakeStarter()..on('$adb -s emulator-5554 wait-for-device');
    android = AndroidDevices(
      sdk: const AndroidSdk('/sdk'),
      run: run.call,
      startDetached: start.call,
      start: waits.call,
      bootTimeout: const Duration(milliseconds: 300),
      pollInterval: Duration.zero,
    );
  });

  void runningPixel() {
    run
      ..on('$adb devices', stdout: '${header}emulator-5554\tdevice\n')
      ..on('$adb -s emulator-5554 emu avd name', stdout: 'qa_pixel_api34\r\nOK\r\n')
      ..on('$adb -s emulator-5554 shell getprop ro.build.version.release', stdout: '14\n')
      ..on('$adb -s emulator-5554 shell getprop ro.build.version.sdk', stdout: '34\n');
  }

  test('list merges AVDs with running emulators', () async {
    runningPixel();
    run.on('$emulator -list-avds', stdout: 'INFO    | Storing crashdata\nqa_pixel_api34\nother_avd\n');
    final devices = await android.list();
    expect(devices.map((d) => (d.name, d.id, d.booted, d.osVersion)), [
      ('qa_pixel_api34', 'qa_pixel_api34', true, 'Android 14 (API 34)'),
      ('other_avd', 'other_avd', false, null),
    ]);
  });

  test('list: a missing SDK is a DeviceToolException', () async {
    run.missing('$emulator -list-avds');
    await expectLater(
      android.list(),
      throwsA(
        isA<DeviceToolException>().having((e) => e.message, 'message', 'Android SDK not found (set ANDROID_HOME)'),
      ),
    );
  });

  test('resolve a running serial', () async {
    runningPixel();
    final ready = await android.resolve('emulator-5554');
    expect(ready.flutterId, 'emulator-5554');
    expect(ready.info.title, 'qa_pixel_api34 (Android 14 (API 34))');
    expect(ready.bootedByUs, isFalse);
  });

  test('a serial that is not running is a LaunchException', () async {
    run.on('$adb devices', stdout: header);
    await expectLater(
      android.resolve('emulator-5556'),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', 'emulator-5556 is not running')),
    );
  });

  test('resolve an AVD that is already running reuses it', () async {
    runningPixel();
    final ready = await android.resolve('qa_pixel_api34');
    expect(ready.flutterId, 'emulator-5554');
    expect(start.started, isEmpty);
  });

  test('resolve an AVD that is shut down boots it and waits for boot_completed', () async {
    run
      ..on('$adb devices', stdout: header)
      ..on('$adb devices', stdout: '${header}emulator-5554\toffline\n')
      ..on('$adb devices', stdout: '${header}emulator-5554\tdevice\n')
      ..on('$emulator -list-avds', stdout: 'qa_pixel_api34\n')
      ..on('$adb -s emulator-5554 emu avd name', stdout: 'qa_pixel_api34\nOK\n')
      ..on('$adb -s emulator-5554 shell getprop sys.boot_completed', stdout: '\n')
      ..on('$adb -s emulator-5554 shell getprop sys.boot_completed', stdout: '1\n')
      ..on('$adb -s emulator-5554 shell am get-config', stdout: 'config: mcc310-mnc260-en-rUS-port-420dpi\n')
      ..on('$adb -s emulator-5554 shell input keyevent 82')
      ..on('$adb -s emulator-5554 shell getprop ro.build.version.release', stdout: '14\n')
      ..on('$adb -s emulator-5554 shell getprop ro.build.version.sdk', stdout: '34\n');
    final booting = <DeviceInfo>[];
    final ready = await android.resolve('qa_pixel_api34', onBooting: booting.add);
    expect(booting.single.name, 'qa_pixel_api34');
    expect(start.started, ['$emulator -avd qa_pixel_api34 -no-snapshot-save -no-boot-anim']);
    expect(ready.flutterId, 'emulator-5554');
    expect(ready.bootedByUs, isTrue);
    expect(ready.info.osVersion, 'Android 14 (API 34)');
    expect(run.calls, contains('$adb -s emulator-5554 shell input keyevent 82'));
  });

  void bootingPixel() {
    run
      ..on('$adb devices', stdout: header)
      ..on('$adb devices', stdout: '${header}emulator-5554\tdevice\n')
      ..on('$emulator -list-avds', stdout: 'qa_pixel_api34\n')
      ..on('$adb -s emulator-5554 emu avd name', stdout: 'qa_pixel_api34\nOK\n')
      ..on('$adb -s emulator-5554 shell getprop sys.boot_completed', stdout: '1\n')
      ..on('$adb -s emulator-5554 shell input keyevent 82')
      ..on('$adb -s emulator-5554 shell getprop ro.build.version.release', stdout: '14\n')
      ..on('$adb -s emulator-5554 shell getprop ro.build.version.sdk', stdout: '34\n');
  }

  test('after boot_completed, waits for the SIM operator to reach the configuration', () async {
    // The mcc/mnc change relaunches the app's activity, which would replace
    // the Flutter engine qa is attached to.
    bootingPixel();
    run
      ..on('$adb -s emulator-5554 shell am get-config', stdout: 'config: en-rUS-port-420dpi\n')
      ..on('$adb -s emulator-5554 shell am get-config', stdout: 'config: en-rUS-port-420dpi\n')
      ..on('$adb -s emulator-5554 shell am get-config', stdout: 'config: mcc310-mnc260-en-rUS-port-420dpi\n');
    await android.resolve('qa_pixel_api34');
    final configPolls = run.calls.where((c) => c.endsWith('am get-config')).length;
    expect(configPolls, 3);
    expect(
      run.calls.indexOf('$adb -s emulator-5554 shell input keyevent 82'),
      greaterThan(run.calls.lastIndexOf('$adb -s emulator-5554 shell am get-config')),
    );
  });

  test('an emulator without a SIM is used once the settle window passes', () async {
    bootingPixel();
    run.on('$adb -s emulator-5554 shell am get-config', stdout: 'config: en-rUS-port-420dpi\n');
    android = AndroidDevices(
      sdk: const AndroidSdk('/sdk'),
      run: run.call,
      startDetached: start.call,
      start: waits.call,
      bootTimeout: const Duration(seconds: 5),
      simSettleTimeout: const Duration(milliseconds: 50),
      pollInterval: const Duration(milliseconds: 5),
    );
    final ready = await android.resolve('qa_pixel_api34');
    expect(ready.flutterId, 'emulator-5554');
    expect(run.calls, contains('$adb -s emulator-5554 shell input keyevent 82'));
  });

  test('an AVD that never boots times out', () async {
    run
      ..on('$adb devices', stdout: header)
      ..on('$emulator -list-avds', stdout: 'qa_pixel_api34\n');
    await expectLater(
      android.resolve('qa_pixel_api34'),
      throwsA(
        isA<LaunchException>().having((e) => e.message, 'message', startsWith('booting qa_pixel_api34 did not finish')),
      ),
    );
  });

  test('a boot that times out kills the wait-for-device', () async {
    run
      ..on('$adb devices', stdout: header)
      ..on('$adb devices', stdout: '${header}emulator-5554\tdevice\n')
      ..on('$emulator -list-avds', stdout: 'qa_pixel_api34\n')
      ..on('$adb -s emulator-5554 emu avd name', stdout: 'qa_pixel_api34\nOK\n');
    waits.on('$adb -s emulator-5554 wait-for-device', hang: true);
    await expectLater(
      android.resolve('qa_pixel_api34'),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', startsWith('booting qa_pixel_api34'))),
    );
    await pumpEventQueue();
    expect(waits.processes['$adb -s emulator-5554 wait-for-device']!.kills, [ProcessSignal.sigterm]);
  });

  test('cancelling a boot kills the wait-for-device', () async {
    run
      ..on('$adb devices', stdout: header)
      ..on('$adb devices', stdout: '${header}emulator-5554\tdevice\n')
      ..on('$emulator -list-avds', stdout: 'qa_pixel_api34\n')
      ..on('$adb -s emulator-5554 emu avd name', stdout: 'qa_pixel_api34\nOK\n');
    waits.on('$adb -s emulator-5554 wait-for-device', hang: true);
    final cancel = CancelSignal();
    final expectation = expectLater(
      android.resolve('qa_pixel_api34', cancel: cancel),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', startsWith('stopped while waiting'))),
    );
    await pumpEventQueue();
    cancel.cancel();
    await expectation;
    await pumpEventQueue();
    expect(waits.processes['$adb -s emulator-5554 wait-for-device']!.kills, [ProcessSignal.sigterm]);
  });

  test('an unknown AVD lists what exists', () async {
    run
      ..on('$adb devices', stdout: header)
      ..on('$emulator -list-avds', stdout: 'a\nb\n');
    await expectLater(
      android.resolve('nope'),
      throwsA(
        isA<LaunchException>().having(
          (e) => e.message,
          'message',
          'no Android emulator (AVD) named "nope"; available: a, b',
        ),
      ),
    );
  });

  test('QA_ANDROID_BOOT_TIMEOUT overrides the default', () {
    expect(AndroidDevices.defaultBootTimeout({}), const Duration(seconds: 180));
    expect(AndroidDevices.defaultBootTimeout({'QA_ANDROID_BOOT_TIMEOUT': '600'}), const Duration(seconds: 600));
    expect(AndroidDevices.defaultBootTimeout({'QA_ANDROID_BOOT_TIMEOUT': 'x'}), const Duration(seconds: 180));
  });

  group('AndroidDeviceController', () {
    late FakeRunner r;
    late AndroidDeviceController c;
    setUp(() {
      r = FakeRunner();
      c = AndroidDeviceController('emulator-5554', sdk: const AndroidSdk('/sdk'), run: r.call);
    });

    test('setOrientation turns off auto-rotate and sets user_rotation', () async {
      r
        ..on('$adb -s emulator-5554 shell settings put system accelerometer_rotation 0')
        ..on('$adb -s emulator-5554 shell settings put system user_rotation 1');
      await c.setOrientation(ScreenOrientation.landscapeLeft, testDriver(FakeAgent(), '/tmp'));
      expect(r.calls, [
        '$adb -s emulator-5554 shell settings put system accelerometer_rotation 0',
        '$adb -s emulator-5554 shell settings put system user_rotation 1',
      ]);
    });

    // The setting returns before the activity has rotated; a screenshot
    // taken straight after would still show the old orientation.
    test('setOrientation returns once the app view has the new orientation', () async {
      r
        ..on('$adb -s emulator-5554 shell settings put system accelerometer_rotation 0')
        ..on('$adb -s emulator-5554 shell settings put system user_rotation 1');
      final agent = FakeAgent();
      var pings = 0;
      agent.on[QaMethod.ping] = (_) {
        pings++;
        final rotated = pings >= 3;
        return {
          'platform': 'android',
          'mode': 'debug',
          'views': [
            {'viewId': 0, 'width': rotated ? 915.0 : 412.0, 'height': rotated ? 412.0 : 915.0, 'devicePixelRatio': 2.6},
          ],
        };
      };
      c = AndroidDeviceController(
        'emulator-5554',
        sdk: const AndroidSdk('/sdk'),
        run: r.call,
        pollInterval: Duration.zero,
      );
      await c.setOrientation(ScreenOrientation.landscapeLeft, testDriver(agent, '/tmp'));
      expect(pings, 3);
    });

    test('setOrientation gives up waiting when the app never rotates', () async {
      r
        ..on('$adb -s emulator-5554 shell settings put system accelerometer_rotation 0')
        ..on('$adb -s emulator-5554 shell settings put system user_rotation 0');
      final agent = FakeAgent();
      var pings = 0;
      agent.on[QaMethod.ping] = (_) {
        pings++;
        return {
          'platform': 'android',
          'mode': 'debug',
          'views': [
            {'viewId': 0, 'width': 915.0, 'height': 412.0, 'devicePixelRatio': 2.6},
          ],
        };
      };
      c = AndroidDeviceController(
        'emulator-5554',
        sdk: const AndroidSdk('/sdk'),
        run: r.call,
        rotationTimeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 5),
      );
      await c.setOrientation(ScreenOrientation.portrait, testDriver(agent, '/tmp'));
      expect(pings, greaterThan(1));
    });

    test('a failed settings put fails setOrientation before waiting for the app', () async {
      r
        ..on('$adb -s emulator-5554 shell settings put system accelerometer_rotation 0')
        ..on('$adb -s emulator-5554 shell settings put system user_rotation 1', stderr: 'device offline', exitCode: 1);
      final agent = FakeAgent();
      await expectLater(
        c.setOrientation(ScreenOrientation.landscapeLeft, testDriver(agent, '/tmp')),
        throwsA(isA<QaException>().having((e) => e.message, 'message', 'setOrientation failed: device offline')),
      );
      expect(agent.argsFor(QaMethod.ping), isEmpty);
    });

    test('a failed accelerometer_rotation put fails setOrientation', () async {
      r.on('$adb -s emulator-5554 shell settings put system accelerometer_rotation 0', stderr: 'denied', exitCode: 255);
      await expectLater(
        c.setOrientation(ScreenOrientation.portrait, testDriver(FakeAgent(), '/tmp')),
        throwsA(isA<QaException>().having((e) => e.message, 'message', 'setOrientation failed: denied')),
      );
      expect(r.calls, hasLength(1));
    });

    test('resetOrientation sets user_rotation 0 without the app', () async {
      r.on('$adb -s emulator-5554 shell settings put system user_rotation 0');
      await c.resetOrientation();
      expect(r.calls, ['$adb -s emulator-5554 shell settings put system user_rotation 0']);
    });

    test('a failed resetOrientation quotes adb', () async {
      r.on('$adb -s emulator-5554 shell settings put system user_rotation 0', stderr: 'device offline', exitCode: 1);
      await expectLater(
        c.resetOrientation(),
        throwsA(isA<QaException>().having((e) => e.message, 'message', 'resetOrientation failed: device offline')),
      );
    });

    test('openLink starts a VIEW intent with the URL quoted for the device shell', () async {
      r.on(
        "$adb -s emulator-5554 shell am start -W -a android.intent.action.VIEW -d 'demo://app/item/42?a=1&b=2'",
        stdout: 'Starting: Intent { }\nStatus: ok\n',
      );
      await c.openLink(Uri.parse('demo://app/item/42?a=1&b=2'));
      expect(r.calls.single, contains("'demo://app/item/42?a=1&b=2'"));
    });

    test('an Error line from am start fails the step', () async {
      r.on(
        "$adb -s emulator-5554 shell am start -W -a android.intent.action.VIEW -d 'demo://x'",
        stdout: 'Starting: Intent { }\nError: Activity not started, unable to resolve Intent\n',
      );
      await expectLater(
        c.openLink(Uri.parse('demo://x')),
        throwsA(
          isA<QaException>().having(
            (e) => e.message,
            'message',
            'openLink demo://x failed: Error: Activity not started, unable to resolve Intent',
          ),
        ),
      );
    });
  });
}
