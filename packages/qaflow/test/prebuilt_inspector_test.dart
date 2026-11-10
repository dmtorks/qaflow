import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('prebuilt_inspector'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A macOS bundle laid out as `flutter build macos` writes it.
  String bundle({String? mode, String? appCode, String? kernel, String name = 'demo.app'}) {
    final app = p.join(dir.path, name);
    final frameworks = p.join(app, 'Contents', 'Frameworks');
    if (mode != null) {
      File(p.join(frameworks, 'FlutterMacOS.framework', 'Resources', 'Info.plist'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
          '\t<key>CFBundleVersion</key>\n\t<string>1.0</string>\n'
          '\t<key>BuildMode</key>\n\t<string>$mode</string>\n</dict>\n</plist>\n',
        );
    }
    if (appCode != null) {
      File(p.join(frameworks, 'App.framework', 'App'))
        ..createSync(recursive: true)
        ..writeAsStringSync(appCode);
    }
    if (kernel != null) {
      File(p.join(frameworks, 'App.framework', 'Resources', 'flutter_assets', 'kernel_blob.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync(kernel);
    }
    return app;
  }

  const withAgent = 'junk \u0000 package:qaflow_agent/src/agent.dart \u0000 more';
  const withoutAgent = 'junk \u0000 package:my_app/main.dart';

  test('a profile build from main_qa.dart can be driven', () {
    final info = inspectPrebuiltApp(bundle(mode: 'profile', appCode: withAgent));
    expect(info.buildMode, 'profile');
    expect(info.hasAgent, isTrue);
    expect(info.problem, isNull);
  });

  test('a debug build is read from its kernel blob', () {
    final info = inspectPrebuiltApp(bundle(mode: 'debug', appCode: 'stub', kernel: withAgent));
    expect(info.buildMode, 'debug');
    expect(info.hasAgent, isTrue);
  });

  test('a release build is refused with the command that fixes it', () {
    final info = inspectPrebuiltApp(bundle(mode: 'release', appCode: withoutAgent));
    expect(info.buildMode, 'release');
    expect(info.isRelease, isTrue);
    expect(info.problem, contains('release build'));
    expect(info.problem, contains('flutter build macos --profile -t lib/main_qa.dart'));
  });

  test('a build without the agent is flagged', () {
    final info = inspectPrebuiltApp(bundle(mode: 'profile', appCode: withoutAgent));
    expect(info.hasAgent, isFalse);
    expect(info.isRelease, isFalse);
    expect(info.problem, contains('qaflow_agent'));
    expect(info.problem, contains('-t lib/main_qa.dart'));
  });

  test('the marker is found across read chunk boundaries', () {
    final padding = 'x' * (prebuiltScanChunkSize - 5);
    final info = inspectPrebuiltApp(bundle(mode: 'profile', appCode: '$padding package:qaflow_agent/x'));
    expect(info.hasAgent, isTrue);
  });

  test('recognises an app built with the qaflow_agent package', () {
    final info = inspectPrebuiltApp(
      bundle(mode: 'profile', appCode: 'junk \u0000 package:qaflow_agent/qaflow_agent.dart'),
    );
    expect(info.hasAgent, isTrue);
  });

  test('recognises an app built with the old qa_agent package', () {
    final info = inspectPrebuiltApp(
      bundle(mode: 'profile', appCode: 'junk \u0000 package:qa_agent/src/agent.dart \u0000'),
    );
    expect(info.hasAgent, isTrue);
    expect(info.problem, isNull);
  });

  test('the old marker is found across read chunk boundaries', () {
    final padding = 'x' * (prebuiltScanChunkSize - 5);
    final info = inspectPrebuiltApp(bundle(mode: 'profile', appCode: '$padding package:qa_agent/x'));
    expect(info.hasAgent, isTrue);
  });

  test('what cannot be read is unknown, never a problem', () {
    final notABundle = inspectPrebuiltApp(p.join(dir.path, 'my_app'));
    expect(notABundle.buildMode, isNull);
    expect(notABundle.hasAgent, isNull);
    expect(notABundle.problem, isNull);

    final noPlist = inspectPrebuiltApp(bundle(appCode: withAgent, name: 'other.app'));
    expect(noPlist.buildMode, isNull);
    expect(noPlist.hasAgent, isTrue);
    expect(noPlist.problem, isNull);
  });
}
