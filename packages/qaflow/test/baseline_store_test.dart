import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceInfo.baselineKey', () {
    test('mobile devices: platform, name and OS, filename-safe', () {
      const ios = DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17 Pro', id: 'U', osVersion: 'iOS 26.5');
      expect(ios.baselineKey(), 'ios-iPhone_17_Pro-iOS_26.5');
      const android = DeviceInfo(
        platform: DevicePlatform.android,
        name: 'qa_pixel_baklava',
        id: 'emulator-5554',
        osVersion: 'Android 15 (API 35)',
      );
      expect(android.baselineKey(), 'android-qa_pixel_baklava-Android_15_API_35');
    });

    test('mobile devices without an OS version, or with a symbol-only name', () {
      const ios = DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17 Pro', id: 'U');
      expect(ios.baselineKey(), 'ios-iPhone_17_Pro');
      const android = DeviceInfo(platform: DevicePlatform.android, name: 'qa_pixel', id: 'emulator-5554');
      expect(android.baselineKey(), 'android-qa_pixel');
      const bare = DeviceInfo(platform: DevicePlatform.android, name: '()', id: 'emulator-5554');
      expect(bare.baselineKey(), 'android-emulator_5554');
    });

    const mac = DeviceInfo(platform: DevicePlatform.macos, name: 'macOS', id: 'macos');

    test('the suffix is cleaned', () {
      expect(mac.baselineKey(suffix: '../x'), 'macos-x');
      expect(mac.baselineKey(suffix: '///'), 'macos');
    });

    test('desktop is the platform name and host OS version; a suffix is appended', () {
      final host = DeviceInfo.desktop(DevicePlatform.macos, hostOsVersion: 'Version 27.0.1 (Build 26A434)');
      expect(host.osVersion, '27.0');
      expect(host.title, 'macOS (27.0)');
      expect(host.baselineKey(), 'macos-27.0');
      expect(host.baselineKey(suffix: 'ci'), 'macos-27.0-ci');
      expect(host.baselineKey(suffix: ''), 'macos-27.0');
      expect(mac.baselineKey(), 'macos');
      expect(
        DeviceInfo.desktop(DevicePlatform.flutterTester, hostOsVersion: 'Version 27.0').baselineKey(),
        'flutter-tester',
      );
      expect(DeviceInfo.desktop(DevicePlatform.macos, hostOsVersion: 'unknown').baselineKey(), 'macos');
    });

    test('host OS versions parse to major.minor', () {
      expect(DeviceInfo.hostVersion('Version 27.0 (Build 26A123)'), '27.0');
      expect(DeviceInfo.hostVersion('Version 14.4.1 (Build 23E224)'), '14.4');
      expect(DeviceInfo.hostVersion('Linux 6.5.0-14-generic #14-Ubuntu SMP PREEMPT_DYNAMIC'), '6.5');
      expect(DeviceInfo.hostVersion('"Windows 10 Pro" 10.0 (Build 19045)'), '10.0');
      expect(DeviceInfo.hostVersion('Version 27 (Build 26A1)'), isNull);
      expect(DeviceInfo.hostVersion(''), isNull);
    });
  });

  group('BaselineStore', () {
    late Directory root;
    late BaselineStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('qa_baselines');
      store = BaselineStore(root.path);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('pathFor', () {
      expect(
        store.pathFor(deviceKey: 'macos', flowSlug: 'login', name: 'home'),
        p.join(root.path, '.qa', 'baselines', 'macos', 'login', 'home.png'),
      );
    });

    test('read is null when missing; write is atomic and creates folders', () {
      final path = store.pathFor(deviceKey: 'macos', flowSlug: 'login', name: 'home');
      expect(store.read(path), isNull);
      store.write(path, [1, 2, 3]);
      expect(store.read(path), [1, 2, 3]);
      store.write(path, [4]);
      expect(store.read(path), [4]);
      expect(Directory(p.dirname(path)).listSync().map((e) => p.basename(e.path)), ['home.png']);
    });

    test('two writers in one process do not share a temporary file', () {
      final path = store.pathFor(deviceKey: 'macos', flowSlug: 'login', name: 'home');
      // Another write's temporary file, in the way of a pid-only name.
      Directory('$path.tmp-$pid').createSync(recursive: true);
      store.write(path, [1, 2, 3]);
      expect(store.read(path), [1, 2, 3]);
    });

    test('nameProblem', () {
      expect(BaselineStore.nameProblem('dialog-open.v2_x'), isNull);
      expect(BaselineStore.nameProblem(''), isNotNull);
      expect(BaselineStore.nameProblem('a/b'), isNotNull);
      expect(BaselineStore.nameProblem('..'), isNotNull);
      expect(BaselineStore.nameProblem('a b'), isNotNull);
    });
  });

  test('ScreenshotComparison round-trips through JSON', () {
    const c = ScreenshotComparison(
      name: 'home',
      baselinePath: '.qa/baselines/macos/login/home.png',
      deviceKey: 'macos',
      outcome: ComparisonOutcome.failed,
      mismatchPercent: 2.31,
      threshold: 0.1,
      actual: 'flows/login/screenshots/home.actual.png',
      baseline: 'flows/login/screenshots/home.baseline.png',
      diff: 'flows/login/screenshots/home.diff.png',
    );
    expect(ScreenshotComparison.fromJson(c.toJson()).toJson(), c.toJson());
    const recorded = ScreenshotComparison(
      name: 'home',
      baselinePath: 'x',
      deviceKey: 'macos',
      outcome: ComparisonOutcome.recorded,
      threshold: 0.1,
      actual: 'a.png',
    );
    expect(recorded.toJson().containsKey('mismatchPercent'), isFalse);
    expect(recorded.toJson().containsKey('diff'), isFalse);
  });
}
