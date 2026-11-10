import 'dart:io';

import '../device/device.dart';

enum BuildMode { debug, profile }

/// The `qa host` that runs the app, reached over an SSH tunnel. Its token
/// never lives here: it comes from `QA_HOST_TOKEN` or QAFlow Studio's settings.
class RemoteHostConfig {
  RemoteHostConfig({Uri? url, required this.project}) : url = url ?? defaultUrl;

  factory RemoteHostConfig.fromJson(Map<String, Object?> json) => RemoteHostConfig(
    url: json['url'] == null ? null : Uri.parse(json['url']! as String),
    project: json['project'] as String,
  );

  static final Uri defaultUrl = Uri.parse('ws://127.0.0.1:7777');

  final Uri url;

  /// The folder on the host that contains `.qa/`, in the host's path style.
  final String project;

  /// Why [url] cannot be a host URL, or null when it can.
  static String? urlProblem(Uri url) => (url.scheme == 'ws' || url.scheme == 'wss') && url.host.isNotEmpty
      ? null
      : 'the host url must look like ws://127.0.0.1:7777, not $url';

  List<String> validate() => [?urlProblem(url), if (project.trim().isEmpty) 'the host project folder is empty'];

  Map<String, Object?> toJson() => {'url': '$url', 'project': project};
}

class ProjectConfig {
  ProjectConfig({
    required this.name,
    this.source,
    this.binary,
    this.entrypoint = 'lib/main_qa.dart',
    this.mode = BuildMode.debug,
    this.flavor,
    this.dartDefines = const {},
    this.env = const {},
    String? device,
    this.flutterPath,
    this.host,
  }) : device = device ?? hostDevice,
       deviceIsDefault = device == null;

  factory ProjectConfig.fromJson(Map<String, Object?> json) => ProjectConfig(
    name: json['name'] as String,
    source: json['source'] as String?,
    binary: json['binary'] as String?,
    entrypoint: json['entrypoint'] as String? ?? 'lib/main_qa.dart',
    mode: BuildMode.values.byName(json['mode'] as String? ?? 'debug'),
    flavor: json['flavor'] as String?,
    dartDefines: (json['dartDefines'] as Map?)?.cast<String, String>() ?? const {},
    env: (json['env'] as Map?)?.cast<String, String>() ?? const {},
    device: json['device'] as String?,
    flutterPath: json['flutterPath'] as String?,
    host: json['host'] == null ? null : RemoteHostConfig.fromJson((json['host']! as Map).cast()),
  );

  static String get hostDevice => Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
      ? 'windows'
      : 'linux';

  final String name;
  final String? source;
  final String? binary;
  final String entrypoint;
  final BuildMode mode;
  final String? flavor;
  final Map<String, String> dartDefines;
  final Map<String, String> env;
  final String device;

  /// [device] was not given, so it is this machine's desktop. A session on
  /// a [host] uses the host's desktop instead.
  final bool deviceIsDefault;

  /// Runs on a [host] with no device given: the host's desktop.
  bool get onHostDesktop => host != null && deviceIsDefault;
  final String? flutterPath;

  /// Set when the app runs on a `qa host`. Then [source], [binary] and
  /// [entrypoint] are paths on that host, and [flutterPath] is unused.
  final RemoteHostConfig? host;

  /// This config with [device] in place of its own.
  ProjectConfig withDevice(String device) => ProjectConfig(
    name: name,
    source: source,
    binary: binary,
    entrypoint: entrypoint,
    mode: mode,
    flavor: flavor,
    dartDefines: dartDefines,
    env: env,
    device: device,
    flutterPath: flutterPath,
    host: host,
  );

  List<String> validate() {
    final errors = <String>[];
    if ((source == null) == (binary == null)) {
      errors.add('exactly one of source or binary must be set');
    }
    // On a host an unset device is the host's desktop, checked once the
    // session knows the host's OS; this machine's default says nothing.
    if (!onHostDesktop) errors.addAll(deviceProblems(device: device, flavor: flavor, binary: binary, mode: mode));
    if (host case final host?) errors.addAll(host.validate());
    return errors;
  }

  /// Shared with the project file parser, which reports them at a position.
  static List<String> deviceProblems({required String device, String? flavor, String? binary, BuildMode? mode}) {
    final DeviceTarget target;
    try {
      target = DeviceTarget.parse(device);
    } on FormatException catch (e) {
      return [e.message];
    }
    return [
      if (flavor != null && target.platform != DevicePlatform.macos && !target.platform.isMobile)
        'flavor is only supported on macos, ios and android devices, not $device',
      if (binary != null && target.platform.isMobile)
        'prebuilt apps are not supported on mobile devices yet; use app.source',
      if (mode == BuildMode.profile && target.platform == DevicePlatform.ios)
        'profile mode is not supported on iOS simulators; use debug',
    ];
  }

  Map<String, Object?> toJson() => {
    'name': name,
    if (source != null) 'source': source,
    if (binary != null) 'binary': binary,
    'entrypoint': entrypoint,
    'mode': mode.name,
    if (flavor != null) 'flavor': flavor,
    'dartDefines': dartDefines,
    'env': env,
    if (!deviceIsDefault) 'device': device,
    if (flutterPath != null) 'flutterPath': flutterPath,
    if (host != null) 'host': host!.toJson(),
  };
}
