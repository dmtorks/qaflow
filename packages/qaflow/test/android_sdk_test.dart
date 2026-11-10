import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  test('ANDROID_HOME, then ANDROID_SDK_ROOT, then the platform default, then PATH', () {
    bool only(String path, String candidate) => path == candidate;
    expect(
      AndroidSdk.locate(environment: {'ANDROID_HOME': '/a', 'ANDROID_SDK_ROOT': '/b'}, exists: (p) => true).root,
      '/a',
    );
    expect(AndroidSdk.locate(environment: {'ANDROID_SDK_ROOT': '/b'}, exists: (p) => only(p, '/b')).root, '/b');
    expect(
      AndroidSdk.locate(
        environment: {'HOME': '/Users/me'},
        operatingSystem: 'macos',
        exists: (p) => only(p, '/Users/me/Library/Android/sdk'),
      ).root,
      '/Users/me/Library/Android/sdk',
    );
    expect(
      AndroidSdk.locate(
        environment: {'HOME': '/home/me'},
        operatingSystem: 'linux',
        exists: (p) => only(p, '/home/me/Android/Sdk'),
      ).root,
      '/home/me/Android/Sdk',
    );
    expect(AndroidSdk.locate(environment: {'HOME': '/x'}, operatingSystem: 'linux', exists: (_) => false).root, isNull);
  });

  test('tool paths', () {
    expect(const AndroidSdk('/sdk').adb, '/sdk/platform-tools/adb');
    expect(const AndroidSdk('/sdk').emulator, '/sdk/emulator/emulator');
    expect(const AndroidSdk(null).adb, 'adb');
  });
}
