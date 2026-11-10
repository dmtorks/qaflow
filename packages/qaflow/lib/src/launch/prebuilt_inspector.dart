import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// What a prebuilt macOS `.app` reveals about whether it can be driven,
/// read from its files without launching it. A field is null when the
/// bundle does not say (another platform's binary, an unusual layout).
class PrebuiltInfo {
  const PrebuiltInfo({this.buildMode, this.hasAgent});

  /// `debug`, `profile` or `release`, from the Flutter engine framework.
  final String? buildMode;

  /// Whether the app's compiled Dart code includes `qaflow_agent`.
  final bool? hasAgent;

  bool get isRelease => buildMode == 'release';

  /// Why this build cannot be driven, with the build command that fixes
  /// it; null when nothing is known to be wrong.
  String? get problem {
    if (isRelease) {
      return 'This is a release build. Release builds have no Dart VM service, so they cannot be driven. '
          'Build it in profile mode from the QA entrypoint instead: flutter build macos --profile -t lib/main_qa.dart';
    }
    if (hasAgent == false) {
      return 'This build does not include qaflow_agent, so nothing in it answers the studio. '
          'Build it from the QA entrypoint: flutter build macos --${buildMode ?? 'profile'} -t lib/main_qa.dart';
    }
    return null;
  }
}

/// Bytes read per step while scanning for [_agentMarkers].
const prebuiltScanChunkSize = 1 << 20;

/// Library URIs stay in compiled Dart for stack traces, so any build that
/// imports the agent contains one of these, in debug (kernel) and AOT alike.
/// `qa_agent` is the agent's name before the QAFlow rename; apps built
/// against it speak the same `ext.qa.*` protocol, so they can still be driven.
final _agentMarkers = [utf8.encode('package:qaflow_agent/'), utf8.encode('package:qa_agent/')];

final _buildMode = RegExp(r'<key>BuildMode</key>\s*<string>(\w+)</string>');

/// Reads [binaryPath] as a macOS `.app` bundle; anything else is unknown.
PrebuiltInfo inspectPrebuiltApp(String binaryPath) {
  if (!binaryPath.endsWith('.app')) return const PrebuiltInfo();
  final frameworks = p.join(binaryPath, 'Contents', 'Frameworks');
  return PrebuiltInfo(
    buildMode: _readBuildMode(p.join(frameworks, 'FlutterMacOS.framework', 'Resources', 'Info.plist')),
    hasAgent: _containsMarker([
      // Debug builds run from kernel; profile and release from the AOT snapshot.
      p.join(frameworks, 'App.framework', 'Resources', 'flutter_assets', 'kernel_blob.bin'),
      p.join(frameworks, 'App.framework', 'App'),
    ]),
  );
}

String? _readBuildMode(String plist) {
  try {
    return _buildMode.firstMatch(File(plist).readAsStringSync())?.group(1);
  } on FileSystemException {
    return null;
  } on FormatException {
    // A binary plist; flutter writes XML, so treat it as unknown.
    return null;
  }
}

/// True if any existing file holds the marker; null if none exists.
bool? _containsMarker(List<String> paths) {
  bool? found;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      if (_scan(file)) return true;
      found = false;
    } on FileSystemException {
      continue;
    }
  }
  return found;
}

bool _scan(File file) {
  final raf = file.openSync();
  try {
    // Each window starts with the previous chunk's last few bytes, so a
    // marker split across two reads is still found.
    final overlap = _agentMarkers.map((m) => m.length).reduce(max) - 1;
    var carry = Uint8List(0);
    while (true) {
      final chunk = raf.readSync(prebuiltScanChunkSize);
      if (chunk.isEmpty) return false;
      final window = Uint8List(carry.length + chunk.length)
        ..setRange(0, carry.length, carry)
        ..setRange(carry.length, carry.length + chunk.length, chunk);
      if (_agentMarkers.any((m) => _indexOf(window, m) >= 0)) return true;
      carry = Uint8List.sublistView(window, window.length > overlap ? window.length - overlap : 0);
    }
  } finally {
    raf.closeSync();
  }
}

int _indexOf(Uint8List haystack, List<int> needle) {
  final first = needle.first;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    if (haystack[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
