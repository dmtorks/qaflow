import 'dart:io';

import 'package:path/path.dart' as p;

/// Where `adb` and `emulator` live. [root] null means "look on PATH".
class AndroidSdk {
  const AndroidSdk(this.root);

  final String? root;

  String get adb => _tool('platform-tools', 'adb');
  String get emulator => _tool('emulator', 'emulator');

  String _tool(String folder, String name) =>
      root == null ? name : p.join(root!, folder, Platform.isWindows ? '$name.exe' : name);

  /// ANDROID_HOME, then ANDROID_SDK_ROOT, then the SDK manager's default
  /// folder for this OS, then PATH.
  static AndroidSdk locate({
    Map<String, String>? environment,
    bool Function(String path)? exists,
    String? operatingSystem,
  }) {
    final env = environment ?? Platform.environment;
    final os = operatingSystem ?? Platform.operatingSystem;
    final has = exists ?? (String path) => Directory(path).existsSync();
    for (final name in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final value = env[name];
      if (value != null && value.isNotEmpty && has(value)) return AndroidSdk(value);
    }
    final home = env['HOME'] ?? env['USERPROFILE'];
    final local = env['LOCALAPPDATA'];
    final candidates = [
      if (os == 'macos' && home != null) p.join(home, 'Library', 'Android', 'sdk'),
      if (os == 'linux' && home != null) p.join(home, 'Android', 'Sdk'),
      if (os == 'windows' && local != null) p.join(local, 'Android', 'Sdk'),
    ];
    for (final c in candidates) {
      if (has(c)) return AndroidSdk(c);
    }
    return const AndroidSdk(null);
  }
}
