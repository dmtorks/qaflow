import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  test('defaults: debug mode, main_qa entrypoint, host device', () {
    final c = ProjectConfig(name: 'demo', source: '/p/demo');
    expect(c.mode, BuildMode.debug);
    expect(c.entrypoint, 'lib/main_qa.dart');
    expect(c.device, ProjectConfig.hostDevice);
    expect(c.validate(), isEmpty);
  });

  test('requires exactly one of source or binary', () {
    expect(ProjectConfig(name: 'x').validate(), contains(contains('source or binary')));
    expect(ProjectConfig(name: 'x', source: '/a', binary: '/b').validate(), contains(contains('source or binary')));
  });

  test('flavor is allowed on macos, ios and android only', () {
    expect(ProjectConfig(name: 'x', source: '/a', device: 'linux', flavor: 'dev').validate(), [
      'flavor is only supported on macos, ios and android devices, not linux',
    ]);
    for (final device in ['macos', 'ios:iPhone 17 Pro', 'android:emulator-5554']) {
      expect(ProjectConfig(name: 'x', source: '/a', device: device, flavor: 'dev').validate(), isEmpty);
    }
  });

  test("a hosted config with no device is not checked against this machine's desktop", () {
    final host = RemoteHostConfig(url: Uri.parse('ws://127.0.0.1:7777'), project: '/srv/app');
    final onHost = ProjectConfig(name: 'x', source: '/a', flavor: 'dev', host: host);
    expect(onHost.onHostDesktop, isTrue);
    expect(onHost.validate(), isEmpty);
    expect(onHost.withDevice('windows').validate(), [
      'flavor is only supported on macos, ios and android devices, not windows',
    ]);
    expect(ProjectConfig(name: 'x', source: '/a', device: 'linux', flavor: 'dev', host: host).validate(), [
      'flavor is only supported on macos, ios and android devices, not linux',
    ]);
  });

  test('an unknown device string is an error', () {
    expect(ProjectConfig(name: 'x', source: '/a', device: 'iPhone 17 Pro').validate(), [
      contains('unknown device "iPhone 17 Pro"'),
    ]);
  });

  test('a prebuilt binary cannot target a mobile device', () {
    expect(ProjectConfig(name: 'x', binary: '/a.app', device: 'ios:iPhone 17 Pro').validate(), [
      'prebuilt apps are not supported on mobile devices yet; use app.source',
    ]);
  });

  test('profile mode cannot target an iOS simulator', () {
    expect(ProjectConfig(name: 'x', source: '/a', device: 'ios:iPhone 17 Pro', mode: BuildMode.profile).validate(), [
      'profile mode is not supported on iOS simulators; use debug',
    ]);
    for (final device in ['android:emulator-5554', 'macos']) {
      expect(ProjectConfig(name: 'x', source: '/a', device: device, mode: BuildMode.profile).validate(), isEmpty);
    }
  });

  test('round-trips JSON', () {
    final c = ProjectConfig(
      name: 'demo',
      source: '/p/demo',
      mode: BuildMode.profile,
      dartDefines: {'A': '1'},
      env: {'B': '2'},
      flutterPath: '/sdk/bin/flutter',
    );
    expect(ProjectConfig.fromJson(c.toJson()).toJson(), equals(c.toJson()));
  });

  test('a host round-trips JSON and is validated', () {
    final c = ProjectConfig(
      name: 'demo',
      source: '.',
      host: RemoteHostConfig(url: Uri.parse('ws://127.0.0.1:9000'), project: r'C:\src\demo'),
    );
    expect(ProjectConfig.fromJson(c.toJson()).toJson(), equals(c.toJson()));
    expect(c.toJson()['host'], {'url': 'ws://127.0.0.1:9000', 'project': r'C:\src\demo'});
    expect(c.validate(), isEmpty);
    expect(RemoteHostConfig(project: '/p').url, Uri.parse('ws://127.0.0.1:7777'));
    expect(
      ProjectConfig(
        name: 'x',
        source: '.',
        host: RemoteHostConfig(project: ' '),
      ).validate(),
      ['the host project folder is empty'],
    );
    expect(
      ProjectConfig(
        name: 'x',
        source: '.',
        host: RemoteHostConfig(url: Uri.parse('http://h'), project: '/p'),
      ).validate(),
      [contains('ws://127.0.0.1:7777')],
    );
  });

  test('a host url missing from JSON defaults to ws://127.0.0.1:7777', () {
    expect(RemoteHostConfig.fromJson({'project': '/p'}).url, Uri.parse('ws://127.0.0.1:7777'));
  });

  test('a device that was not given stays a default through JSON', () {
    final c = ProjectConfig(name: 'x', source: '/a');
    expect(c.deviceIsDefault, isTrue);
    expect(ProjectConfig.fromJson(c.toJson()).deviceIsDefault, isTrue);
    final given = ProjectConfig(name: 'x', source: '/a', device: 'linux');
    expect(given.deviceIsDefault, isFalse);
    expect(ProjectConfig.fromJson(given.toJson()).device, 'linux');
    expect(given.withDevice('windows').deviceIsDefault, isFalse);
  });
}
