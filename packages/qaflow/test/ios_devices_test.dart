import 'dart:convert';
import 'dart:io';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'fake_process.dart';
import 'flow_test_support.dart';

const _list = 'xcrun simctl list devices available -j';

String simctlJson() => jsonEncode({
  'devices': {
    'com.apple.CoreSimulator.SimRuntime.iOS-18-2': [
      {'udid': 'OLD-17', 'isAvailable': true, 'state': 'Shutdown', 'name': 'iPhone 17 Pro'},
      {'udid': 'SE-3', 'isAvailable': true, 'state': 'Shutdown', 'name': 'iPhone SE (3rd generation)'},
    ],
    'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
      {'udid': 'NEW-17', 'isAvailable': true, 'state': 'Shutdown', 'name': 'iPhone 17 Pro'},
      {'udid': 'AIR', 'isAvailable': true, 'state': 'Booted', 'name': 'iPhone Air'},
    ],
    'com.apple.CoreSimulator.SimRuntime.watchOS-26-2': [
      {'udid': 'WATCH', 'isAvailable': true, 'state': 'Shutdown', 'name': 'Apple Watch Series 11 (46mm)'},
    ],
  },
});

void main() {
  late FakeRunner run;
  late FakeStarter starter;
  late IosDevices ios;
  setUp(() {
    run = FakeRunner()..on(_list, stdout: simctlJson());
    starter = FakeStarter();
    ios = IosDevices(run: run.call, start: starter.call, bootTimeout: const Duration(milliseconds: 200));
  });

  test('list: iOS runtimes only, newest runtime first', () async {
    final devices = await ios.list();
    expect(devices.map((d) => (d.id, d.osVersion, d.booted)), [
      ('NEW-17', 'iOS 26.5', false),
      ('AIR', 'iOS 26.5', true),
      ('OLD-17', 'iOS 18.2', false),
      ('SE-3', 'iOS 18.2', false),
    ]);
    expect(devices.every((d) => d.platform == DevicePlatform.ios), isTrue);
  });

  test('list: missing xcrun and a failing simctl are DeviceToolExceptions', () async {
    final missing = FakeRunner()..missing(_list);
    await expectLater(
      IosDevices(run: missing.call).list(),
      throwsA(
        isA<DeviceToolException>().having((e) => e.message, 'message', 'Xcode command line tools not found (xcrun)'),
      ),
    );
    final failing = FakeRunner()..on(_list, stderr: 'boom', exitCode: 1);
    await expectLater(
      IosDevices(run: failing.call).list(),
      throwsA(isA<DeviceToolException>().having((e) => e.message, 'message', 'xcrun simctl failed: boom')),
    );
  });

  test('resolve a booted device by name: no boot', () async {
    run.on('open -a Simulator');
    var booting = 0;
    final ready = await ios.resolve('iPhone Air', onBooting: (_) => booting++);
    expect(ready.flutterId, 'AIR');
    expect(ready.bootedByUs, isFalse);
    expect(booting, 0);
    expect(run.calls, [_list, 'open -a Simulator']);
  });

  test('resolve by name picks the newest runtime and boots it', () async {
    run
      ..on('xcrun simctl boot NEW-17')
      ..on('open -a Simulator');
    starter.on('xcrun simctl bootstatus NEW-17 -b');
    final booting = <DeviceInfo>[];
    final ready = await ios.resolve('iPhone 17 Pro', onBooting: booting.add);
    expect(ready.flutterId, 'NEW-17');
    expect(ready.bootedByUs, isTrue);
    expect(ready.info.booted, isTrue);
    expect(ready.info.title, 'iPhone 17 Pro (iOS 26.5)');
    expect(booting.single.id, 'NEW-17');
    expect(run.calls, [_list, 'xcrun simctl boot NEW-17', 'open -a Simulator']);
    expect(starter.calls, ['xcrun simctl bootstatus NEW-17 -b']);
  });

  test('resolve by UDID, case-insensitively', () async {
    run
      ..on('xcrun simctl boot OLD-17')
      ..on('open -a Simulator');
    starter.on('xcrun simctl bootstatus OLD-17 -b');
    expect((await ios.resolve('old-17')).flutterId, 'OLD-17');
  });

  test('an already-booted error from boot is ignored', () async {
    run
      ..on('xcrun simctl boot NEW-17', stderr: 'Unable to boot device in current state: Booted', exitCode: 149)
      ..on('open -a Simulator');
    starter.on('xcrun simctl bootstatus NEW-17 -b');
    expect((await ios.resolve('iPhone 17 Pro')).flutterId, 'NEW-17');
  });

  test('a boot that times out kills the bootstatus wait', () async {
    run.on('xcrun simctl boot NEW-17');
    starter.on('xcrun simctl bootstatus NEW-17 -b', hang: true);
    await expectLater(
      ios.resolve('iPhone 17 Pro'),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', startsWith('booting iPhone 17 Pro'))),
    );
    await pumpEventQueue();
    expect(starter.processes['xcrun simctl bootstatus NEW-17 -b']!.kills, [ProcessSignal.sigterm]);
  });

  test('cancelling a boot kills the bootstatus wait', () async {
    run.on('xcrun simctl boot NEW-17');
    starter.on('xcrun simctl bootstatus NEW-17 -b', hang: true);
    final cancel = CancelSignal();
    final result = ios.resolve('iPhone 17 Pro', cancel: cancel);
    final expectation = expectLater(
      result,
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', startsWith('stopped while waiting'))),
    );
    await pumpEventQueue();
    cancel.cancel();
    await expectation;
    await pumpEventQueue();
    expect(starter.processes['xcrun simctl bootstatus NEW-17 -b']!.kills, [ProcessSignal.sigterm]);
  });

  test('not found lists up to five names', () async {
    await expectLater(
      ios.resolve('iPhone 99'),
      throwsA(
        isA<LaunchException>().having(
          (e) => e.message,
          'message',
          'no iOS simulator named "iPhone 99"; available: iPhone 17 Pro, iPhone Air, iPhone SE (3rd generation)',
        ),
      ),
    );
  });

  test('a boot failure is a LaunchException', () async {
    run.on('xcrun simctl boot NEW-17', stderr: 'disk full', exitCode: 1);
    await expectLater(
      ios.resolve('iPhone 17 Pro'),
      throwsA(
        isA<LaunchException>().having(
          (e) => e.message,
          'message',
          'could not boot iPhone 17 Pro (iOS 26.5): disk full',
        ),
      ),
    );
  });

  test('the boot timeout is 120 s, or QA_IOS_BOOT_TIMEOUT seconds', () {
    expect(IosDevices.defaultBootTimeout({}), const Duration(seconds: 120));
    expect(IosDevices.defaultBootTimeout({'QA_IOS_BOOT_TIMEOUT': '600'}), const Duration(seconds: 600));
    expect(IosDevices.defaultBootTimeout({'QA_IOS_BOOT_TIMEOUT': 'x'}), const Duration(seconds: 120));
    expect(IosDevices.defaultBootTimeout({'QA_IOS_BOOT_TIMEOUT': '0'}), const Duration(seconds: 120));
    expect(IosDevices(environment: {'QA_IOS_BOOT_TIMEOUT': '300'}).bootTimeout, const Duration(seconds: 300));
  });

  group('IosDeviceController', () {
    test('openLink runs simctl openurl', () async {
      final r = FakeRunner()..on('xcrun simctl openurl U1 demo://app/item/42');
      await IosDeviceController('U1', run: r.call).openLink(Uri.parse('demo://app/item/42'));
      expect(r.calls, ['xcrun simctl openurl U1 demo://app/item/42']);
    });

    test('a failed openLink is a step failure quoting simctl', () async {
      final r = FakeRunner()..on('xcrun simctl openurl U1 demo://x', stderr: 'no handler', exitCode: 1);
      await expectLater(
        IosDeviceController('U1', run: r.call).openLink(Uri.parse('demo://x')),
        throwsA(isA<QaException>().having((e) => e.message, 'message', 'openLink demo://x failed: no handler')),
      );
    });

    test('setOrientation goes through the agent', () async {
      final agent = FakeAgent();
      final driver = testDriver(agent, '/tmp');
      await IosDeviceController('U1', run: FakeRunner().call).setOrientation(ScreenOrientation.landscapeRight, driver);
      expect(agent.argsFor(QaMethod.setOrientation).single, {'orientation': 'landscapeRight'});
    });

    test('resetOrientation runs nothing: the rotation lives in the app', () async {
      final r = FakeRunner();
      await IosDeviceController('U1', run: r.call).resetOrientation();
      expect(r.calls, isEmpty);
    });
  });
}
