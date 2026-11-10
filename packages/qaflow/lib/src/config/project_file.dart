import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../flow/runner.dart' show ScreenshotPolicy;
import '../flow/variables.dart';
import '../screenshot/screenshot_comparison.dart';
import 'project_config.dart';

/// A problem in a project file, at a 1-based [line] and [column].
class ProjectFileException implements Exception {
  ProjectFileException(this.file, this.line, this.column, this.message);
  final String file;
  final int line;
  final int column;
  final String message;
  @override
  String toString() => '$file:$line:$column: $message';
}

/// `.qa/project.yaml`: which app to launch and how to run its flows, shared
/// by `qa test` and QAFlow Studio. Relative paths in the file resolve against
/// [appRoot], the parent of the folder holding the file (normally the folder
/// that contains `.qa/`), except the app's paths when a `host:` is set: those
/// are paths on the host and are kept as written.
class ProjectFile {
  const ProjectFile({
    required this.path,
    required this.config,
    required this.flowFolders,
    this.flowEnv = const {},
    this.secrets = const [],
    this.retries = 0,
    this.screenshots = ScreenshotPolicy.failures,
    this.baselines = BaselineMode.record,
    this.includeTags = const {},
    this.excludeTags = const {},
    this.sourceAsWritten,
    this.binaryAsWritten,
  });

  static const String relativePath = '.qa/project.yaml';

  /// Absolute, normalised path of the file.
  final String path;

  /// Source or binary as absolute paths, or as written when [ProjectConfig.host]
  /// is set. `flutterPath` is always null: where Flutter lives belongs to the
  /// machine, not the project.
  final ProjectConfig config;

  /// `app.source` and `app.binary` as the file has them, so a host given on
  /// the command line gets host paths and `--host none` local ones.
  final String? sourceAsWritten;
  final String? binaryAsWritten;

  /// Absolute folder paths.
  final List<String> flowFolders;

  /// Flow variables, like `qa test --env`.
  final Map<String, String> flowEnv;

  /// Flow variables whose values must come from outside the file.
  final List<String> secrets;
  final int retries;
  final ScreenshotPolicy screenshots;
  final BaselineMode baselines;
  final Set<String> includeTags;
  final Set<String> excludeTags;

  String get appRoot => p.dirname(p.dirname(path));

  /// [config] run on [host] instead of the file's own host (null: this
  /// machine). The app's paths are as written for a host, and resolved
  /// against [appRoot] otherwise.
  ProjectConfig configWithHost(RemoteHostConfig? host) {
    String? local(String? written, String? resolved) =>
        written == null ? resolved : p.normalize(p.join(appRoot, written));
    final c = config;
    return ProjectConfig(
      name: c.name,
      source: host == null ? local(sourceAsWritten, c.source) : sourceAsWritten ?? c.source,
      binary: host == null ? local(binaryAsWritten, c.binary) : binaryAsWritten ?? c.binary,
      entrypoint: c.entrypoint,
      mode: c.mode,
      flavor: c.flavor,
      dartDefines: c.dartDefines,
      env: c.env,
      device: c.deviceIsDefault ? null : c.device,
      flutterPath: c.flutterPath,
      host: host,
    );
  }

  /// `qa test`'s baselines mode: [flag] (`--baselines`) when given, else
  /// [file]'s `flows.baselines`, else `record`.
  static BaselineMode baselinesFor(String? flag, ProjectFile? file) =>
      flag == null ? file?.baselines ?? BaselineMode.record : BaselineMode.values.byName(flag);

  /// Where `qa test` keeps baselines: [file]'s app root, else the
  /// `--project` folder; null when there is neither (only `--binary`).
  static String? appRootFor(ProjectFile? file, String? project) =>
      file?.appRoot ?? (project == null ? null : p.absolute(project));

  /// `<dir>/.qa/project.yaml` when that file exists.
  static String? findIn(String dir) {
    final candidate = p.normalize(p.join(p.absolute(dir), '.qa', 'project.yaml'));
    return File(candidate).existsSync() ? candidate : null;
  }

  static ProjectFile load(String path) {
    final absolute = p.normalize(p.absolute(path));
    final String text;
    try {
      text = File(absolute).readAsStringSync();
    } on FileSystemException catch (e) {
      throw ProjectFileException(absolute, 1, 1, 'cannot read the project file: ${e.osError?.message ?? e.message}');
    }
    return parse(text, absolute);
  }

  /// Parses [text] as the file at [path].
  static ProjectFile parse(String text, String path) => _Parser(p.normalize(p.absolute(path))).parse(text);
}

typedef _Entry = (YamlNode key, YamlNode value);

class _Parser {
  _Parser(this.file) : root = p.dirname(p.dirname(file));

  final String file;
  final String root;

  static const Set<String> topKeys = {'name', 'app', 'flows', 'host'};
  static const Set<String> hostKeys = {'url', 'project'};
  static const Set<String> appKeys = {
    'source',
    'binary',
    'entrypoint',
    'mode',
    'device',
    'flavor',
    'dartDefines',
    'env',
  };
  static const Set<String> flowKeys = {
    'folders',
    'env',
    'secrets',
    'retries',
    'screenshots',
    'baselines',
    'includeTags',
    'excludeTags',
  };

  Never fail(YamlNode node, String message) {
    final start = node.span.start;
    throw ProjectFileException(file, start.line + 1, start.column + 1, message);
  }

  ProjectFile parse(String text) {
    final YamlNode doc;
    try {
      doc = loadYamlNode(text, sourceUrl: Uri.file(file));
    } on YamlException catch (e) {
      final start = e.span?.start;
      throw ProjectFileException(file, (start?.line ?? 0) + 1, (start?.column ?? 0) + 1, e.message);
    }
    if (doc.value == null) throw ProjectFileException(file, 1, 1, 'the project file is empty; it needs an app section');
    final top = entries(doc, 'the project file', topKeys);
    final app = top['app'] ?? fail(doc, 'the project file needs an app section');
    final name = optionalString(top['name'], 'name') ?? p.basename(root);
    final host = top['host'] == null ? null : hostConfig(top['host']!);
    final (config, source, binary) = appConfig(app.$2, name, host);
    final flows = top['flows'];
    final f = flows == null || flows.$2.value == null ? const <String, _Entry>{} : entries(flows.$2, 'flows', flowKeys);
    final env = f['env'] == null ? const <String, String>{} : stringMap(f['env']!.$2, 'flows env', variables: true);
    final folders = f['folders'] == null
        ? [p.join(root, '.qa', 'flows')]
        : [for (final s in stringList(f['folders']!.$2, 'folders')) resolve(s)];
    if (folders.isEmpty) fail(f['folders']!.$2, 'folders must name at least one folder');
    return ProjectFile(
      path: file,
      config: config,
      sourceAsWritten: source,
      binaryAsWritten: binary,
      flowFolders: folders,
      flowEnv: env,
      secrets: f['secrets'] == null ? const [] : secretNames(f['secrets']!.$2, env),
      retries: f['retries'] == null ? 0 : wholeNumber(f['retries']!.$2, 'retries'),
      screenshots: f['screenshots'] == null
          ? ScreenshotPolicy.failures
          : choice(f['screenshots']!.$2, 'screenshots', ScreenshotPolicy.values),
      baselines: f['baselines'] == null
          ? BaselineMode.record
          : choice(
              f['baselines']!.$2,
              'baselines',
              BaselineMode.values,
              message: 'baselines must be record, strict or update',
            ),
      includeTags: f['includeTags'] == null ? const {} : stringList(f['includeTags']!.$2, 'includeTags').toSet(),
      excludeTags: f['excludeTags'] == null ? const {} : stringList(f['excludeTags']!.$2, 'excludeTags').toSet(),
    );
  }

  RemoteHostConfig hostConfig(_Entry entry) {
    final node = entry.$2;
    // `host:` alone is reported at the key; its null value has no useful position.
    if (node.value == null) fail(entry.$1, 'host needs project, the project folder on the host');
    if (node is YamlMap) {
      for (final key in node.nodes.keys) {
        if ((key as YamlNode).value == 'token') {
          fail(key, 'the host token is never read from the project file; set QA_HOST_TOKEN instead');
        }
      }
    }
    final e = entries(node, 'host', hostKeys);
    final project = optionalString(e['project'], 'project');
    if (project == null || project.trim().isEmpty) {
      fail(e['project']?.$2 ?? node, 'host needs project, the project folder on the host');
    }
    final rawUrl = optionalString(e['url'], 'url');
    final url = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (rawUrl != null) {
      final problem = url == null
          ? 'the host url must look like ws://127.0.0.1:7777'
          : RemoteHostConfig.urlProblem(url);
      if (problem != null) fail(e['url']!.$2, problem);
    }
    return RemoteHostConfig(url: url, project: project);
  }

  /// The app's config, and its source and binary as written. With a
  /// [host], the app's paths are paths there: kept as written and not
  /// resolved against this machine's project folder.
  (ProjectConfig, String?, String?) appConfig(YamlNode node, String name, RemoteHostConfig? host) {
    String? path(String? written) => written == null || host != null ? written : resolve(written);
    final e = entries(node, 'app', appKeys);
    final source = optionalString(e['source'], 'source');
    final binary = optionalString(e['binary'], 'binary');
    if ((source == null) == (binary == null)) {
      fail(e['binary']?.$1 ?? node, 'app needs exactly one of source or binary');
    }
    final flavor = optionalString(e['flavor'], 'flavor');
    final config = ProjectConfig(
      name: name,
      source: path(source),
      binary: path(binary),
      entrypoint: optionalString(e['entrypoint'], 'entrypoint') ?? 'lib/main_qa.dart',
      mode: e['mode'] == null ? BuildMode.debug : choice(e['mode']!.$2, 'mode', BuildMode.values),
      device: optionalString(e['device'], 'device'),
      flavor: flavor,
      dartDefines: e['dartDefines'] == null ? const {} : stringMap(e['dartDefines']!.$2, 'dartDefines'),
      env: e['env'] == null ? const {} : stringMap(e['env']!.$2, 'app env'),
      host: host,
    );
    // A hosted project with no device runs on the host's desktop, which the
    // session checks against the host's OS after it connects.
    final problems = config.onHostDesktop
        ? const <String>[]
        : ProjectConfig.deviceProblems(device: config.device, flavor: flavor, binary: binary, mode: config.mode);
    if (problems.isNotEmpty) {
      final message = problems.first;
      final at = message.startsWith('flavor')
          ? e['flavor']!.$2
          : message.startsWith('profile')
          ? e['mode']!.$2
          : (e['device']?.$2 ?? node);
      fail(at, message);
    }
    return (config, source, binary);
  }

  List<String> secretNames(YamlNode node, Map<String, String> env) {
    if (node is! YamlList) fail(node, 'secrets must be a list of variable names');
    final names = <String>[];
    for (final item in node.nodes) {
      final name = string(item, 'a secret name');
      if (!isVariableName(name)) fail(item, 'invalid variable name $name');
      if (env.containsKey(name)) fail(item, '$name is listed as a secret and also given a value in flows env');
      if (names.contains(name)) fail(item, '$name is listed twice');
      names.add(name);
    }
    return names;
  }

  Map<String, _Entry> entries(YamlNode node, String what, Set<String> allowed) {
    if (node is! YamlMap) fail(node, '$what must be a map');
    final out = <String, _Entry>{};
    for (final e in node.nodes.entries) {
      final key = e.key as YamlNode;
      final name = key.value;
      if (name is! String || !allowed.contains(name)) {
        fail(key, 'unknown key "$name" in $what; expected ${allowed.join(', ')}');
      }
      out[name] = (key, e.value);
    }
    return out;
  }

  String? optionalString(_Entry? e, String what) => e == null || e.$2.value == null ? null : string(e.$2, what);

  String string(YamlNode node, String what) {
    final v = node.value;
    if (v is String) return v;
    if (v is num || v is bool) return '$v';
    fail(node, '$what must be a string');
  }

  List<String> stringList(YamlNode node, String what) {
    if (node is! YamlList) fail(node, '$what must be a list');
    return [for (final item in node.nodes) string(item, 'each entry of $what')];
  }

  Map<String, String> stringMap(YamlNode node, String what, {bool variables = false}) {
    if (node is! YamlMap) fail(node, '$what must be a map of names to values');
    final out = <String, String>{};
    for (final e in node.nodes.entries) {
      final key = e.key as YamlNode;
      final name = key.value;
      if (name is! String || name.isEmpty || name.contains('=')) fail(key, 'invalid name in $what');
      if (variables && !isVariableName(name)) fail(key, 'invalid variable name $name');
      if (e.value.value == null) fail(e.value, 'value for $name in $what is missing');
      out[name] = string(e.value, 'value for $name');
    }
    return out;
  }

  int wholeNumber(YamlNode node, String what) {
    final v = node.value;
    if (v is! int) fail(node, '$what must be a whole number');
    if (v < 0) fail(node, '$what must be at least 0');
    return v;
  }

  T choice<T extends Enum>(YamlNode node, String what, List<T> values, {String? message}) {
    for (final v in values) {
      if (v.name == node.value) return v;
    }
    fail(node, message ?? '$what must be one of ${values.map((v) => v.name).join(', ')}');
  }

  String resolve(String path) => p.normalize(p.join(root, path));

  static bool isVariableName(String name) {
    try {
      VariableScope.parseAssignments(['$name=']);
      return true;
    } on FormatException {
      return false;
    }
  }
}
