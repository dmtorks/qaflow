// Tests for the repo's release tool (tool/release.dart at the workspace root),
// and the check that the three published packages share one version. They
// live here so CI's `dart test` in packages/qaflow runs them; .pubignore keeps
// this file out of the published package, since it imports from outside it.

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/src/release.dart';

const _agentPubspec = '''
name: qaflow_agent
description: The agent.
version: 0.1.0 # kept in step by tool/release.dart
resolution: workspace
environment:
  sdk: ^3.12.0
  flutter: ">=3.44.0"
dependencies:
  flutter:
    sdk: flutter
  # The wire types.
  qaflow_protocol: ^0.1.0   # shared version
dev_dependencies:
  flutter_test:
    sdk: flutter
''';

String _pubspec(String name, String version, {String deps = ''}) =>
    'name: $name\nversion: $version\nenvironment:\n  sdk: ^3.12.0\n$deps';

Map<String, String> _workspace(String version, {String constraint = '^0.1.0'}) => {
  'qaflow_protocol': _pubspec('qaflow_protocol', version),
  'qaflow_agent': _pubspec('qaflow_agent', version, deps: 'dependencies:\n  qaflow_protocol: $constraint\n'),
  'qaflow': _pubspec('qaflow', version, deps: 'dependencies:\n  path: ^1.9.1\n  qaflow_protocol: $constraint\n'),
};

void main() {
  group('Version', () {
    test('parses releases and prereleases', () {
      expect('${Version.parse('0.1.0')}', '0.1.0');
      expect('${Version.parse('1.20.3-dev.1')}', '1.20.3-dev.1');
    });

    for (final bad in ['1.0', 'v1.0.0', '1.0.0.0', '01.0.0', '1.0.0-', '1.0.0+build', '', 'latest']) {
      test('rejects "$bad"', () => expect(() => Version.parse(bad), throwsA(isA<ReleaseException>())));
    }

    test('orders by semver precedence', () {
      final ordered = ['0.1.0', '0.1.1', '0.2.0-dev', '0.2.0-dev.2', '0.2.0-dev.10', '0.2.0-rc.1', '0.2.0', '1.0.0'];
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(Version.parse(ordered[i + 1]) > Version.parse(ordered[i]), isTrue, reason: ordered[i + 1]);
        expect(Version.parse(ordered[i]) > Version.parse(ordered[i + 1]), isFalse, reason: ordered[i]);
      }
      expect(Version.parse('0.2.0'), Version.parse('0.2.0'));
    });
  });

  group('setVersion', () {
    test('changes only the version and keeps its comment', () {
      final bumped = setVersion(_agentPubspec, '0.2.0');
      expect(bumped, _agentPubspec.replaceFirst('version: 0.1.0 #', 'version: 0.2.0 #'));
      expect(readVersion(bumped), '0.2.0');
    });

    test('ignores an indented version key', () {
      expect(readVersion('name: x\ndependencies:\n  foo:\n    version: ^1.0.0\n'), isNull);
    });
  });

  group('rewriteConstraints', () {
    test('sets the caret on sibling packages and keeps comments and layout', () {
      final rewritten = rewriteConstraints(_agentPubspec, '0.2.0');
      expect(rewritten, _agentPubspec.replaceFirst('qaflow_protocol: ^0.1.0   #', 'qaflow_protocol: ^0.2.0   #'));
    });

    test('leaves the sdk constraint, other packages and non-caret forms alone', () {
      const pubspec = '''
name: qaflow
version: 0.1.0
environment:
  sdk: ^0.1.0
dependencies:
  args: ^0.1.0
  qaflow_protocol: "^0.1.0"
dev_dependencies:
  qaflow_agent:
    path: ../qaflow_agent
dependency_overrides:
  qaflow_protocol: ^0.1.0
''';
      final rewritten = rewriteConstraints(pubspec, '0.3.0-dev.1');
      expect(rewritten, pubspec.replaceFirst('"^0.1.0"', '"^0.3.0-dev.1"'));
    });
  });

  group('addChangelogEntry', () {
    final day = DateTime(2026, 3, 4);

    test('prepends a dated entry with a placeholder', () {
      const changelog = '## 0.1.0\n\n- Initial public release.\n';
      expect(
        addChangelogEntry(changelog, '0.2.0', day),
        '## 0.2.0 - 2026-03-04\n\n$changelogPlaceholder\n\n## 0.1.0\n\n- Initial public release.\n',
      );
    });

    test('is idempotent', () {
      final once = addChangelogEntry('## 0.1.0\n\n- First.\n', '0.2.0', day);
      expect(addChangelogEntry(once, '0.2.0', DateTime(2027)), once);
    });

    test('leaves an existing hand-written entry alone', () {
      const changelog = '## 0.2.0\n\n- Real notes.\n\n## 0.1.0\n';
      expect(addChangelogEntry(changelog, '0.2.0', day), changelog);
    });

    test('does not mistake a longer version for this one', () {
      expect(hasChangelogEntry('## 0.2.0-dev.1\n', '0.2.0'), isFalse);
      expect(hasChangelogEntry('## 0.2.0 - 2026-01-01\n', '0.2.0'), isTrue);
    });

    test('starts an empty changelog', () {
      expect(addChangelogEntry('', '0.1.0', day), '## 0.1.0 - 2026-03-04\n\n$changelogPlaceholder\n');
    });
  });

  group('checkVersionsAgree', () {
    test('passes when versions and constraints match', () {
      expect(checkVersionsAgree(_workspace('0.1.0')), isEmpty);
    });

    test('reports differing versions', () {
      final pubspecs = _workspace('0.1.0')..['qaflow'] = _pubspec('qaflow', '0.1.1');
      expect(checkVersionsAgree(pubspecs), [contains('must share one version')]);
    });

    test('reports a constraint that does not match the shared version', () {
      expect(checkVersionsAgree(_workspace('0.2.0')), hasLength(2));
      expect(checkVersionsAgree(_workspace('0.1.0', constraint: '">=0.1.0 <0.2.0"')), [
        contains('qaflow_agent/pubspec.yaml dependencies has qaflow_protocol: >=0.1.0 <0.2.0, expected ^0.1.0'),
        contains('expected ^0.1.0'),
      ]);
    });

    test('reports a path dependency between the packages', () {
      final pubspecs = _workspace('0.1.0')
        ..['qaflow'] = _pubspec('qaflow', '0.1.0', deps: 'dependencies:\n  qaflow_protocol:\n    path: ../p\n');
      expect(checkVersionsAgree(pubspecs), [contains('non-inline form')]);
    });

    test('the repo packages agree', () {
      final pubspecs = {for (final name in releasedPackages) name: File('../$name/pubspec.yaml').readAsStringSync()};
      expect(checkVersionsAgree(pubspecs), isEmpty);
    });
  });

  group('planRelease', () {
    late Directory root;
    final day = DateTime(2026, 11, 10);

    setUp(() {
      root = Directory.systemTemp.createTempSync('qaflow_release_');
      for (final MapEntry(key: name, value: pubspec) in _workspace('0.1.0').entries) {
        File('${root.path}/packages/$name/pubspec.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync(pubspec);
        File('${root.path}/packages/$name/CHANGELOG.md').writeAsStringSync('## 0.1.0\n\n- First.\n');
      }
      File('${root.path}/$qaVersionFile')
        ..createSync(recursive: true)
        ..writeAsStringSync("const hostProtocolVersion = 1;\n\nconst qaVersion = '0.1.0';\n");
    });

    tearDown(() => root.deleteSync(recursive: true));

    String read(String path) => File('${root.path}/$path').readAsStringSync();

    test('bumps every package, constraint, changelog and qaVersion', () {
      final plan = planRelease(root.path, '0.2.0', day);
      expect('${plan.from}', '0.1.0');
      expect('${plan.to}', '0.2.0');
      applyRelease(root.path, plan);

      expect(checkVersionsAgree({for (final n in releasedPackages) n: read('packages/$n/pubspec.yaml')}), isEmpty);
      expect(read('packages/qaflow/pubspec.yaml'), _workspace('0.2.0', constraint: '^0.2.0')['qaflow']);
      for (final name in releasedPackages) {
        expect(read('packages/$name/CHANGELOG.md'), startsWith('## 0.2.0 - 2026-11-10\n\n$changelogPlaceholder\n'));
      }
      expect(read(qaVersionFile), contains("const qaVersion = '0.2.0';"));
    });

    test('a patch release moves the constraints to the patch', () {
      applyRelease(root.path, planRelease(root.path, '0.1.1', day));
      expect(read('packages/qaflow_agent/pubspec.yaml'), contains('qaflow_protocol: ^0.1.1\n'));
    });

    for (final version in ['0.1.0', '0.0.9', '0.1.0-dev.1']) {
      test('refuses $version, which is not above 0.1.0', () {
        expect(
          () => planRelease(root.path, version, day),
          throwsA(isA<ReleaseException>().having((e) => e.message, 'message', contains('not greater'))),
        );
      });
    }

    test('refuses a malformed version without touching files', () {
      expect(() => planRelease(root.path, '0.2', day), throwsA(isA<ReleaseException>()));
      expect(read('packages/qaflow/pubspec.yaml'), _workspace('0.1.0')['qaflow']);
    });

    test('refuses when the packages are already out of step', () {
      File('${root.path}/packages/qaflow/pubspec.yaml').writeAsStringSync(_pubspec('qaflow', '0.1.1'));
      expect(
        () => planRelease(root.path, '0.2.0', day),
        throwsA(isA<ReleaseException>().having((e) => e.message, 'message', contains('out of step'))),
      );
    });

    test('next steps give the tags in publish order', () {
      final steps = nextSteps(Version.parse('0.2.0'));
      final protocol = steps.indexOf('git push origin qaflow_protocol-v0.2.0');
      final agent = steps.indexOf('git push origin qaflow_agent-v0.2.0');
      final qaflow = steps.indexOf('git push origin qaflow-v0.2.0');
      expect(protocol, greaterThan(0));
      expect(agent, greaterThan(protocol));
      expect(qaflow, greaterThan(agent));
      expect(steps, contains('git tag qaflow_protocol-v0.2.0'));
    });
  });
}
