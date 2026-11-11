/// The release bump behind `tool/release.dart`, kept apart from the script so
/// packages/qaflow/test/release_tool_test.dart can drive it on strings and on
/// a temporary copy of the repo.
///
/// The YAML is edited line by line rather than through package:yaml_edit,
/// because the workspace root (which owns tool/) has no dependency on it.
/// The edits only touch the `version:` line and the inline caret constraints
/// between the packages, so comments and layout survive.
library;

import 'dart:io';

/// The published packages, in publish order: the later ones depend on
/// qaflow_protocol, so it has to be live on pub.dev first.
const releasedPackages = ['qaflow_protocol', 'qaflow_agent', 'qaflow'];

/// The bullet a new CHANGELOG entry starts with. The publish workflow refuses
/// a CHANGELOG that still contains it.
const changelogPlaceholder = '- Describe the changes in this release.';

/// The file holding `qaVersion`, which `qa host` reports in `hello` and a
/// test keeps equal to packages/qaflow/pubspec.yaml.
const qaVersionFile = 'packages/qaflow/lib/src/remote/host_protocol.dart';

class ReleaseException implements Exception {
  ReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A semver version: `x.y.z`, optionally followed by `-prerelease`.
class Version implements Comparable<Version> {
  Version(this.major, this.minor, this.patch, [this.prerelease = const []]);

  static final _pattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?$',
  );

  factory Version.parse(String text) {
    final m = _pattern.firstMatch(text);
    if (m == null) {
      throw ReleaseException('"$text" is not a version. Use x.y.z, optionally with a prerelease suffix (0.2.0-dev.1).');
    }
    return Version(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m[4]?.split('.') ?? const []);
  }

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  @override
  int compareTo(Version other) {
    for (final (a, b) in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    // A prerelease sorts before the release it leads up to.
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final c = _compareIdentifier(prerelease[i], other.prerelease[i]);
      if (c != 0) return c;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  static int _compareIdentifier(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease.join('.'));

  @override
  String toString() => '$major.$minor.$patch${prerelease.isEmpty ? '' : '-${prerelease.join('.')}'}';
}

final _versionLine = RegExp(r'^version:[ \t]*(\S+)(.*)$', multiLine: true);

/// The top-level `version:` of [pubspec], or null when it has none.
String? readVersion(String pubspec) => _versionLine.firstMatch(pubspec)?[1];

/// [pubspec] with its top-level `version:` set to [version].
String setVersion(String pubspec, String version) {
  if (readVersion(pubspec) == null) throw ReleaseException('pubspec has no top-level version: line');
  return pubspec.replaceFirstMapped(_versionLine, (m) => 'version: $version${m[2]}');
}

const _dependencySections = {'dependencies', 'dev_dependencies'};
final _topLevelKey = RegExp(r'^([A-Za-z_][\w-]*)[ \t]*:');
final _dependencyLine = RegExp(r'^([ \t]+)([A-Za-z_]\w*)([ \t]*:[ \t]*)(.*)$');

/// One dependency of a pubspec on another released package.
typedef SiblingDependency = ({String section, String name, String constraint});

/// Calls [visit] for each line of [pubspec] that declares a dependency on one
/// of [releasedPackages], and returns the lines with whatever [visit] made of
/// them. [visit] gets the match and returns the new line.
List<String> _mapSiblingLines(String pubspec, String Function(String section, RegExpMatch m) visit) {
  String? section;
  return [
    for (final line in pubspec.split('\n'))
      () {
        final top = _topLevelKey.firstMatch(line);
        if (top != null) {
          section = top[1];
          return line;
        }
        final m = _dependencyLine.firstMatch(line);
        if (m == null || !_dependencySections.contains(section) || !releasedPackages.contains(m[2])) return line;
        return visit(section!, m);
      }(),
  ];
}

/// Splits `^0.1.0   # comment` into the value and what follows it.
(String, String) _splitValue(String rest) {
  final m = RegExp(r'''^("[^"]*"|'[^']*'|[^\s#]*)(.*)$''').firstMatch(rest)!;
  return (m[1]!, m[2]!);
}

String _unquote(String value) {
  if (value.length >= 2 && (value[0] == '"' || value[0] == "'") && value[value.length - 1] == value[0]) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// The dependencies [pubspec] declares on the other released packages, with
/// the constraint as written. A dependency written as a block (a `path:` or
/// `version:` under the name) has an empty constraint.
List<SiblingDependency> siblingDependencies(String pubspec) {
  final found = <SiblingDependency>[];
  _mapSiblingLines(pubspec, (section, m) {
    final (value, _) = _splitValue(m[4]!);
    found.add((section: section, name: m[2]!, constraint: value.startsWith('#') ? '' : _unquote(value)));
    return m[0]!;
  });
  return found;
}

/// [pubspec] with every caret constraint on another released package set to
/// `^version`. Other forms (a `path:` block, an exact pin) are left alone;
/// [checkVersionsAgree] reports them.
String rewriteConstraints(String pubspec, String version) {
  return _mapSiblingLines(pubspec, (section, m) {
    final (value, trailing) = _splitValue(m[4]!);
    if (!_unquote(value).startsWith('^')) return m[0]!;
    final quote = value.startsWith('"') || value.startsWith("'") ? value[0] : '';
    return '${m[1]}${m[2]}${m[3]}$quote^$version$quote$trailing';
  }).join('\n');
}

/// Whether [changelog] already has a `## <version>` heading.
bool hasChangelogEntry(String changelog, String version) =>
    RegExp('^## ${RegExp.escape(version)}(?:[ \t]|\$)', multiLine: true).hasMatch(changelog);

/// [changelog] with a `## <version> - <date>` entry and a placeholder bullet
/// on top, or unchanged when it already has an entry for [version].
String addChangelogEntry(String changelog, String version, DateTime date) {
  if (hasChangelogEntry(changelog, version)) return changelog;
  final day = '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}';
  final entry = '## $version - $day\n\n$changelogPlaceholder\n';
  return changelog.trim().isEmpty ? entry : '$entry\n$changelog';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// What is wrong with the versions of the released packages, given each
/// package's pubspec text by name. Empty when they share one version and
/// every constraint between them is `^<that version>`.
List<String> checkVersionsAgree(Map<String, String> pubspecs) {
  final problems = <String>[];
  final versions = {for (final name in releasedPackages) name: readVersion(pubspecs[name] ?? '')};
  for (final MapEntry(key: name, value: v) in versions.entries) {
    if (v == null) problems.add('packages/$name/pubspec.yaml has no version: line');
  }
  final distinct = versions.values.nonNulls.toSet();
  if (distinct.length > 1) {
    problems.add(
      'the packages must share one version, but they have '
      '${versions.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
    );
  }
  if (distinct.length != 1) return problems;
  final shared = distinct.single;
  for (final name in releasedPackages) {
    for (final dep in siblingDependencies(pubspecs[name] ?? '')) {
      if (dep.constraint != '^$shared') {
        final written = dep.constraint.isEmpty ? 'a non-inline form' : dep.constraint;
        problems.add('packages/$name/pubspec.yaml ${dep.section} has ${dep.name}: $written, expected ^$shared');
      }
    }
  }
  return problems;
}

/// The file changes a release makes, by path relative to the repo root.
typedef ReleasePlan = ({Version from, Version to, Map<String, String> files});

/// Works out the changes for releasing [version] from the repo at [root],
/// without writing anything. Throws [ReleaseException] when [version] is not
/// a version, is not above the current one, or the repo is not in a state to
/// bump (the packages already disagree).
ReleasePlan planRelease(String root, String version, DateTime today) {
  final to = Version.parse(version);
  String read(String path) {
    final file = File('$root/$path');
    if (!file.existsSync()) throw ReleaseException('$path not found. Run this from the qaflow repo root.');
    return file.readAsStringSync();
  }

  final pubspecs = {for (final name in releasedPackages) name: read('packages/$name/pubspec.yaml')};
  final problems = checkVersionsAgree(pubspecs);
  if (problems.isNotEmpty) {
    throw ReleaseException('The packages are out of step; fix this first:\n  ${problems.join('\n  ')}');
  }
  final from = Version.parse(readVersion(pubspecs.values.first)!);
  if (!(to > from)) throw ReleaseException('$to is not greater than the current version $from.');

  final files = <String, String>{};
  for (final name in releasedPackages) {
    files['packages/$name/pubspec.yaml'] = rewriteConstraints(setVersion(pubspecs[name]!, '$to'), '$to');
    final changelog = 'packages/$name/CHANGELOG.md';
    files[changelog] = addChangelogEntry(File('$root/$changelog').existsSync() ? read(changelog) : '', '$to', today);
  }
  final hostProtocol = read(qaVersionFile);
  final qaVersion = RegExp(r"^const qaVersion = '[^']*';", multiLine: true);
  if (!qaVersion.hasMatch(hostProtocol)) throw ReleaseException('$qaVersionFile has no qaVersion constant');
  files[qaVersionFile] = hostProtocol.replaceFirst(qaVersion, "const qaVersion = '$to';");
  return (from: from, to: to, files: files);
}

/// Writes the files of [plan] under [root].
void applyRelease(String root, ReleasePlan plan) {
  for (final MapEntry(key: path, value: text) in plan.files.entries) {
    File('$root/$path').writeAsStringSync(text);
  }
}

/// The steps after the bump: the PR, then the tags in publish order.
String nextSteps(Version version) {
  final tags = [for (final name in releasedPackages) '$name-v$version'];
  return '''
Bumped ${releasedPackages.join(', ')} to $version.

Next:
  1. Replace "${changelogPlaceholder.substring(2)}" in each CHANGELOG.md with the real changes.
  2. Commit on a branch and open a PR:
       git checkout -b chore/release-$version
       git add ${[for (final n in releasedPackages) 'packages/$n/pubspec.yaml packages/$n/CHANGELOG.md'].join(' ')} $qaVersionFile
       git commit -m "chore: release $version"
       git push -u origin chore/release-$version
  3. After the PR merges, tag the merge commit on main and push the tags in this order. Each tag
     publishes its package (.github/workflows/publish.yml). Wait until qaflow_protocol
     shows $version on pub.dev before pushing the other two, because qaflow_agent and
     qaflow resolve qaflow_protocol ^$version from pub.dev:
       git tag ${tags[0]}
       git push origin ${tags[0]}
       # wait for https://pub.dev/packages/qaflow_protocol to show $version
       git tag ${tags[1]}
       git push origin ${tags[1]}
       git tag ${tags[2]}
       git push origin ${tags[2]}
''';
}
