import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('qa_project'));
  tearDown(() => root.deleteSync(recursive: true));

  String rootPath() => p.normalize(root.absolute.path);

  String write(String yaml) {
    final file = File(p.join(root.path, '.qa', 'project.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(yaml);
    return file.path;
  }

  void expectError(String yaml, int line, int column, String message) {
    expect(
      () => ProjectFile.load(write(yaml)),
      throwsA(
        isA<ProjectFileException>()
            .having((e) => (e.line, e.column), 'position', (line, column))
            .having((e) => e.message, 'message', contains(message)),
      ),
    );
  }

  test('a minimal file gets the defaults', () {
    final f = ProjectFile.load(write('app:\n  source: .\n'));
    expect(f.path, p.join(rootPath(), '.qa', 'project.yaml'));
    expect(f.appRoot, rootPath());
    expect(f.config.name, p.basename(rootPath()));
    expect(f.config.source, rootPath());
    expect(f.config.binary, isNull);
    expect(f.config.entrypoint, 'lib/main_qa.dart');
    expect(f.config.mode, BuildMode.debug);
    expect(f.config.device, ProjectConfig.hostDevice);
    expect(f.config.flutterPath, isNull);
    expect(f.flowFolders, [p.join(rootPath(), '.qa', 'flows')]);
    expect(f.flowEnv, isEmpty);
    expect(f.secrets, isEmpty);
    expect(f.retries, 0);
    expect(f.screenshots, ScreenshotPolicy.failures);
    expect(f.baselines, BaselineMode.record);
    expect(f.includeTags, isEmpty);
    expect(f.excludeTags, isEmpty);
  });

  test('every field is read, and relative paths resolve against the app root', () {
    final f = ProjectFile.load(
      write('''
name: Demo
app:
  binary: build/Demo.app
  entrypoint: lib/qa.dart
  mode: profile
  device: macos
  flavor: dev
  dartDefines:
    API_URL: http://localhost:8080
  env:
    LOG_LEVEL: debug
flows:
  folders: [.qa/smoke, /abs/flows]
  env:
    USERNAME: demo
    RETRY_COUNT: 3
  secrets: [PASSWORD]
  retries: 2
  screenshots: all
  baselines: strict
  includeTags: [smoke]
  excludeTags: [slow, flaky]
'''),
    );
    expect(f.config.name, 'Demo');
    expect(f.config.source, isNull);
    expect(f.config.binary, p.join(rootPath(), 'build', 'Demo.app'));
    expect(f.config.entrypoint, 'lib/qa.dart');
    expect(f.config.mode, BuildMode.profile);
    expect(f.config.device, 'macos');
    expect(f.config.flavor, 'dev');
    expect(f.config.dartDefines, {'API_URL': 'http://localhost:8080'});
    expect(f.config.env, {'LOG_LEVEL': 'debug'});
    expect(f.flowFolders, [p.join(rootPath(), '.qa', 'smoke'), '/abs/flows']);
    expect(f.flowEnv, {'USERNAME': 'demo', 'RETRY_COUNT': '3'});
    expect(f.secrets, ['PASSWORD']);
    expect(f.retries, 2);
    expect(f.screenshots, ScreenshotPolicy.all);
    expect(f.baselines, BaselineMode.strict);
    expect(f.includeTags, {'smoke'});
    expect(f.excludeTags, {'slow', 'flaky'});
  });

  group('errors carry the line and column', () {
    test(
      'unknown top-level key',
      () => expectError('app:\n  source: .\ncolour: red\n', 3, 1, 'unknown key "colour" in the project file'),
    );
    test('unknown app key', () => expectError('app:\n  source: .\n  sorce: x\n', 3, 3, 'unknown key "sorce" in app'));
    test(
      'both source and binary',
      () => expectError('app:\n  source: .\n  binary: a.app\n', 3, 3, 'exactly one of source or binary'),
    );
    test(
      'neither source nor binary',
      () => expectError('app:\n  entrypoint: lib/main_qa.dart\n', 2, 3, 'exactly one of source or binary'),
    );
    test(
      'bad mode',
      () => expectError('app:\n  source: .\n  mode: release\n', 3, 9, 'mode must be one of debug, profile'),
    );
    test(
      'negative retries',
      () => expectError('app:\n  source: .\nflows:\n  retries: -1\n', 4, 12, 'retries must be at least 0'),
    );
    test(
      'bad screenshots',
      () => expectError(
        'app:\n  source: .\nflows:\n  screenshots: sometimes\n',
        4,
        16,
        'screenshots must be one of failures, all, none',
      ),
    );
    test(
      'bad baselines',
      () => expectError(
        'app:\n  source: .\nflows:\n  baselines: sometimes\n',
        4,
        14,
        'baselines must be record, strict or update',
      ),
    );
    test(
      'a secret that also has a value',
      () => expectError(
        'app:\n  source: .\nflows:\n  env:\n    PASSWORD: x\n  secrets: [PASSWORD]\n',
        6,
        13,
        'PASSWORD is listed as a secret and also given a value',
      ),
    );
    test(
      'flavor off macOS',
      () => expectError(
        'app:\n  source: .\n  device: windows\n  flavor: dev\n',
        4,
        11,
        'flavor is only supported on macos, ios and android devices',
      ),
    );
    test(
      'unknown device',
      () => expectError('app:\n  source: .\n  device: iPhone 17 Pro\n', 3, 11, 'unknown device "iPhone 17 Pro"'),
    );
    test(
      'binary on a mobile device',
      () => expectError(
        'app:\n  binary: build/app.app\n  device: ios:iPhone 17 Pro\n',
        3,
        11,
        'prebuilt apps are not supported on mobile devices yet',
      ),
    );
    test(
      'profile mode on an iOS simulator',
      () => expectError(
        'app:\n  source: .\n  device: ios:iPhone 17 Pro\n  mode: profile\n',
        4,
        9,
        'profile mode is not supported on iOS simulators; use debug',
      ),
    );
    test('flavor on a simulator is fine', () {
      final file = ProjectFile.load(write('app:\n  source: .\n  device: ios:iPhone 17 Pro\n  flavor: dev\n'));
      expect(file.config.flavor, 'dev');
      expect(file.config.device, 'ios:iPhone 17 Pro');
    });
    test(
      'bad flow variable name',
      () => expectError('app:\n  source: .\nflows:\n  env:\n    1ABC: x\n', 5, 5, 'invalid variable name 1ABC'),
    );
    test(
      'no flow folders',
      () => expectError('app:\n  source: .\nflows:\n  folders: []\n', 4, 12, 'at least one folder'),
    );
    test('no app section', () => expectError('flows:\n  retries: 1\n', 1, 1, 'needs an app section'));
    test('an empty file', () => expectError('', 1, 1, 'empty'));
    test('a YAML syntax error', () {
      expect(() => ProjectFile.load(write('app: [unclosed\n')), throwsA(isA<ProjectFileException>()));
    });
  });

  group('qa test baselines and app root', () {
    test('--baselines wins over the project file, which wins over record', () {
      final strict = ProjectFile.load(write('app:\n  source: .\nflows:\n  baselines: strict\n'));
      expect(ProjectFile.baselinesFor('update', strict), BaselineMode.update);
      expect(ProjectFile.baselinesFor(null, strict), BaselineMode.strict);
      expect(ProjectFile.baselinesFor(null, null), BaselineMode.record);
      expect(ProjectFile.baselinesFor('strict', null), BaselineMode.strict);
    });

    test('the app root is the project file\'s, else the --project folder', () {
      final file = ProjectFile.load(write('app:\n  source: .\n'));
      expect(ProjectFile.appRootFor(file, '/elsewhere'), rootPath());
      expect(ProjectFile.appRootFor(null, 'demo'), p.absolute('demo'));
      expect(ProjectFile.appRootFor(null, null), isNull);
    });
  });

  group('host', () {
    test('url defaults to ws://127.0.0.1:7777 and project is kept', () {
      final f = ProjectFile.load(write('app:\n  source: .\nhost:\n  project: C:\\src\\myapp\n'));
      expect(f.config.host?.url, Uri.parse('ws://127.0.0.1:7777'));
      expect(f.config.host?.project, r'C:\src\myapp');
    });

    test('an explicit url is read', () {
      final f = ProjectFile.load(write('app:\n  source: .\nhost:\n  url: ws://127.0.0.1:9000\n  project: /srv/app\n'));
      expect(f.config.host?.url, Uri.parse('ws://127.0.0.1:9000'));
    });

    test('app paths are host paths: kept as written and not checked here', () {
      final f = ProjectFile.load(
        write('app:\n  binary: build/nowhere/app.exe\n  entrypoint: lib/qa.dart\nhost:\n  project: /srv/app\n'),
      );
      expect(f.config.binary, 'build/nowhere/app.exe');
      expect(f.config.source, isNull);
      expect(f.config.entrypoint, 'lib/qa.dart');
      expect(File(p.join(rootPath(), 'build', 'nowhere', 'app.exe')).existsSync(), isFalse);
      expect(f.config.validate(), isEmpty);
    });

    test('a flavor with no device is left for the session to check against the host', () {
      final f = ProjectFile.load(write('app:\n  source: .\n  flavor: dev\nhost:\n  project: /srv/app\n'));
      expect(f.config.flavor, 'dev');
      expect(f.config.onHostDesktop, isTrue);
      expect(f.config.validate(), isEmpty);
    });

    test('without a host app paths still resolve against the app root', () {
      final f = ProjectFile.load(write('app:\n  source: sub\n'));
      expect(f.config.source, p.join(rootPath(), 'sub'));
      expect(f.config.host, isNull);
    });

    test('configWithHost gives host paths for a host and local ones for none', () {
      final hosted = ProjectFile.load(write('app:\n  source: sub\nhost:\n  project: /srv/app\n'));
      expect(hosted.configWithHost(null).source, p.join(rootPath(), 'sub'));
      expect(hosted.configWithHost(null).host, isNull);
      final local = ProjectFile.load(write('app:\n  source: sub\n'));
      final other = RemoteHostConfig(project: '/srv/other');
      expect(local.configWithHost(other).source, 'sub');
      expect(local.configWithHost(other).host, same(other));
    });

    test(
      'project is required',
      () => expectError('app:\n  source: .\nhost:\n  url: ws://127.0.0.1:7777\n', 4, 3, 'host needs project'),
    );
    test(
      'a blank project is an error',
      () => expectError('app:\n  source: .\nhost:\n  project: ""\n', 4, 12, 'host needs project'),
    );

    test(
      'a host: with no value needs a project',
      () => expectError('app:\n  source: .\nhost:\n', 3, 1, 'host needs project'),
    );

    test(
      'the token is never read from the file',
      () => expectError('app:\n  source: .\nhost:\n  project: /srv/app\n  token: abc\n', 5, 3, 'set QA_HOST_TOKEN'),
    );

    test(
      'a url that is not ws:// is an error',
      () => expectError('app:\n  source: .\nhost:\n  url: http://h:1\n  project: /p\n', 4, 8, 'ws://127.0.0.1:7777'),
    );

    test(
      'an unknown host key is an error',
      () => expectError('app:\n  source: .\nhost:\n  project: /p\n  port: 1\n', 5, 3, 'unknown key "port" in host'),
    );
  });

  test('a missing file is a ProjectFileException at 1:1', () {
    expect(
      () => ProjectFile.load(p.join(root.path, 'nope.yaml')),
      throwsA(isA<ProjectFileException>().having((e) => (e.line, e.column), 'position', (1, 1))),
    );
  });

  test('findIn returns .qa/project.yaml only when it exists', () {
    expect(ProjectFile.findIn(root.path), isNull);
    write('app:\n  source: .\n');
    expect(ProjectFile.findIn(root.path), p.join(rootPath(), '.qa', 'project.yaml'));
  });
}
