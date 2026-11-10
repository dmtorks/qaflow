import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

class FakeMobile implements MobileDevices {
  FakeMobile(this.devices, {this.error});
  final List<DeviceInfo> devices;
  final DeviceToolException? error;
  final List<String> resolved = [];

  @override
  Future<List<DeviceInfo>> list() async => error == null ? devices : throw error!;

  @override
  Future<ReadyDevice> resolve(String query, {void Function(DeviceInfo device)? onBooting, CancelSignal? cancel}) async {
    resolved.add(query);
    final d = devices.firstWhere((d) => d.name == query);
    onBooting?.call(d);
    return ReadyDevice(flutterId: d.id, info: d, controller: const UnsupportedDeviceController(DevicePlatform.ios));
  }
}

void main() {
  const iphone = DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17 Pro', id: 'U1', osVersion: 'iOS 26.5');
  const pixel = DeviceInfo(
    platform: DevicePlatform.android,
    name: 'qa_pixel_api34',
    id: 'qa_pixel_api34',
    booted: false,
  );

  test('list: host, flutter-tester, then iOS, then Android', () async {
    final m = DeviceManager(
      ios: FakeMobile([iphone]),
      android: FakeMobile([pixel]),
      isMacOS: true,
      host: DevicePlatform.macos,
    );
    final l = await m.list();
    expect(l.devices.map((d) => d.id), ['macos', 'flutter-tester', 'U1', 'qa_pixel_api34']);
    expect(l.problems, isEmpty);
  });

  test('list: a failing toolchain becomes a problem, not an exception', () async {
    final m = DeviceManager(
      ios: FakeMobile(const [], error: DeviceToolException('Xcode command line tools not found (xcrun)')),
      android: FakeMobile(const [], error: DeviceToolException('Android SDK not found (set ANDROID_HOME)')),
      isMacOS: true,
      host: DevicePlatform.macos,
    );
    final l = await m.list();
    expect(l.devices.map((d) => d.id), ['macos', 'flutter-tester']);
    expect(l.problems.map((p) => (p.platform, p.message)), [
      (DevicePlatform.ios, 'Xcode command line tools not found (xcrun)'),
      (DevicePlatform.android, 'Android SDK not found (set ANDROID_HOME)'),
    ]);
  });

  test('list: iOS off macOS is a problem', () async {
    final l = await DeviceManager(
      ios: FakeMobile([iphone]),
      android: FakeMobile(const []),
      isMacOS: false,
      host: DevicePlatform.linux,
    ).list();
    expect(l.problems.first.message, 'iOS simulators need macOS');
    expect(l.devices.map((d) => d.id), ['linux', 'flutter-tester']);
  });

  test('resolve: desktop needs no tools', () async {
    final ready = await DeviceManager(
      android: FakeMobile(const []),
      isMacOS: true,
      host: DevicePlatform.macos,
      hostOsVersion: 'Version 27.0.1 (Build 26A434)',
    ).resolve(DeviceTarget.parse('macos'));
    expect(ready.flutterId, 'macos');
    expect(ready.info.title, 'macOS (27.0)');
    expect(ready.info.baselineKey(), 'macos-27.0');
    expect(ready.controller, isA<UnsupportedDeviceController>());
  });

  test('resolve: ios delegates and passes onBooting through', () async {
    final ios = FakeMobile([iphone]);
    final booting = <DeviceInfo>[];
    final ready = await DeviceManager(
      ios: ios,
      android: FakeMobile(const []),
      isMacOS: true,
    ).resolve(DeviceTarget.parse('ios:iPhone 17 Pro'), onBooting: booting.add);
    expect(ready.flutterId, 'U1');
    expect(ios.resolved, ['iPhone 17 Pro']);
    expect(booting.single.id, 'U1');
  });

  test('resolve: ios off macOS is a LaunchException', () async {
    await expectLater(
      DeviceManager(
        ios: FakeMobile([iphone]),
        android: FakeMobile(const []),
        isMacOS: false,
      ).resolve(DeviceTarget.parse('ios:iPhone 17 Pro')),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', 'iOS simulators need macOS')),
    );
  });

  test('resolve: android delegates', () async {
    final ready = await DeviceManager(
      android: FakeMobile([pixel]),
      ios: FakeMobile(const []),
      isMacOS: true,
    ).resolve(DeviceTarget.parse('android:qa_pixel_api34'));
    expect(ready.flutterId, 'qa_pixel_api34');
  });
}
