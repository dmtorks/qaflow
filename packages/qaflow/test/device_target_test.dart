import 'dart:async';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceTarget.parse', () {
    test('desktop names', () {
      expect(DeviceTarget.parse('macos').platform, DevicePlatform.macos);
      expect(DeviceTarget.parse('windows').platform, DevicePlatform.windows);
      expect(DeviceTarget.parse('linux').platform, DevicePlatform.linux);
      expect(DeviceTarget.parse('flutter-tester').platform, DevicePlatform.flutterTester);
      expect(DeviceTarget.parse('macos').query, isNull);
    });

    test('ios and android prefixes keep the rest as the query', () {
      final ios = DeviceTarget.parse('ios:iPhone 17 Pro');
      expect(ios.platform, DevicePlatform.ios);
      expect(ios.query, 'iPhone 17 Pro');
      final android = DeviceTarget.parse('android: emulator-5554 ');
      expect(android.platform, DevicePlatform.android);
      expect(android.query, 'emulator-5554');
    });

    test('toString writes the same form back', () {
      for (final s in ['macos', 'flutter-tester', 'ios:iPhone 17 Pro', 'android:qa_pixel_api34']) {
        expect(DeviceTarget.parse(s).toString(), s);
      }
    });

    test('errors', () {
      Matcher error(String message) =>
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(message)));
      expect(() => DeviceTarget.parse('ios:'), error('ios: needs a simulator name or UDID'));
      expect(() => DeviceTarget.parse('android:'), error('android: needs an AVD name or emulator serial'));
      expect(() => DeviceTarget.parse('iPhone 17 Pro'), error('unknown device "iPhone 17 Pro"'));
      expect(() => DeviceTarget.parse('iPhone 17 Pro'), error('(e.g. "ios:iPhone 17 Pro")'));
      expect(() => DeviceTarget.parse('tvos:x'), error('unknown device "tvos:x"'));
    });
  });

  test('DeviceInfo round-trips through JSON and has a title', () {
    const info = DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17 Pro', id: 'ABC', osVersion: 'iOS 26.5');
    expect(DeviceInfo.fromJson(info.toJson()).toJson(), info.toJson());
    expect(info.toJson(), {'platform': 'ios', 'name': 'iPhone 17 Pro', 'id': 'ABC', 'osVersion': 'iOS 26.5'});
    expect(info.title, 'iPhone 17 Pro (iOS 26.5)');
    expect(DeviceInfo.desktop(DevicePlatform.macos, hostOsVersion: '').title, 'macOS');
    expect(DeviceInfo.desktop(DevicePlatform.macos, hostOsVersion: 'Version 27.0').title, 'macOS (27.0)');
    expect(DeviceInfo.desktop(DevicePlatform.macos).id, 'macos');
  });

  test('UnsupportedDeviceController answers unsupported', () async {
    const c = UnsupportedDeviceController(DevicePlatform.macos);
    await expectLater(
      c.openLink(Uri.parse('demo://app/item/1')),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.unsupported)),
    );
    await c.resetOrientation();
  });

  group('guardDeviceWait', () {
    test('returns the work result', () async {
      expect(await guardDeviceWait(Future.value(3), timeout: const Duration(seconds: 1), what: 'x'), 3);
    });

    test('times out with a LaunchException naming what', () async {
      await expectLater(
        guardDeviceWait(Completer<int>().future, timeout: const Duration(milliseconds: 20), what: 'booting X'),
        throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('booting X did not finish'))),
      );
    });

    test('a cancel ends the wait', () async {
      final cancel = CancelSignal();
      final wait = guardDeviceWait(
        Completer<int>().future,
        timeout: const Duration(seconds: 5),
        what: 'X',
        cancel: cancel,
      );
      cancel.cancel();
      await expectLater(
        wait,
        throwsA(isA<LaunchException>().having((e) => e.message, 'message', 'stopped while waiting for X')),
      );
      expect(cancel.isCancelled, isTrue);
    });
  });
}
