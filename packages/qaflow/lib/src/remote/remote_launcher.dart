import 'dart:async';

import '../config/project_config.dart';
import '../launch/launched_app.dart';
import 'host_protocol.dart';
import 'remote_host.dart';

/// Launches the app on a QA host. The returned app's VM service is the
/// host's proxy for it, so the session connects to it as to a local one.
class RemoteLauncher implements AppLauncher {
  RemoteLauncher(
    this.host,
    this.hostUrl,
    this.token,
    this.config,
    this.projectOnHost,
    this.flutterId, {
    this.stopTimeout = const Duration(seconds: 10),
    this.onLaunched,
    this.onStopped,
  });

  final RemoteHost host;
  final Uri hostUrl;
  final String token;

  /// Its source, binary and entrypoint are paths on the host.
  final ProjectConfig config;

  /// The folder on the host that contains `.qa/`.
  final String projectOnHost;
  final String flutterId;

  /// How long [LaunchedApp.stop] waits for the host's `app.exit`.
  final Duration stopTimeout;

  /// Told the host's id for each app this launches, and again once the host
  /// has stopped it, so a later connection can stop any left running.
  final void Function(String appId)? onLaunched;
  final void Function(String appId)? onStopped;

  Map<String, Object?> get _appParams => {
    if (config.source != null) 'source': config.source,
    if (config.binary != null) 'binary': config.binary,
    'entrypoint': config.entrypoint,
    'mode': config.mode.name,
    if (config.flavor != null) 'flavor': config.flavor,
    'dartDefines': config.dartDefines,
    'env': config.env,
  };

  @override
  Future<LaunchedApp> start() async {
    // Notifications are taken from before the request is sent, so a log line
    // or exit that arrives with the response is not missed.
    final early = <HostNotification>[];
    final exited = Completer<int>();
    String? appId;

    // Lines that arrive before anyone listens (with the app.start response,
    // or before the session subscribes) are kept and replayed to the first
    // listener; a broadcast stream would drop them.
    final backlog = <String>[];
    var listened = false;
    var closeWhenListened = false;
    late final StreamController<String> logs;
    logs = StreamController<String>.broadcast(
      onListen: () {
        if (listened) return;
        listened = true;
        backlog.forEach(logs.add);
        backlog.clear();
        if (closeWhenListened) unawaited(logs.close());
      },
    );
    void addLine(String line) => listened ? logs.add(line) : backlog.add(line);
    unawaited(exited.future.whenComplete(() => listened ? logs.close() : closeWhenListened = true));

    void deliver(HostNotification n) {
      if (n.params['appId'] != appId) return;
      switch (n.method) {
        case 'app.log':
          addLine(n.params['line']! as String);
        case 'app.exit':
          if (!exited.isCompleted) exited.complete((n.params['code'] as num?)?.toInt() ?? -1);
      }
    }

    final subscription = host.notifications.listen((n) => appId == null ? early.add(n) : deliver(n));
    // A lost host is a dead app as far as this session can tell.
    unawaited(host.done.then((_) => exited.isCompleted ? null : exited.complete(-1)));

    final Map<String, Object?> result;
    try {
      result = await host.launchCall('app.start', {
        'project': projectOnHost,
        'app': _appParams,
        'flutterId': flutterId,
      });
    } catch (_) {
      await subscription.cancel();
      rethrow;
    }
    final id = appId = result['appId']! as String;
    onLaunched?.call(id);
    early.forEach(deliver);
    early.clear();
    unawaited(exited.future.whenComplete(subscription.cancel));

    return LaunchedApp(
      appId: id,
      wsUri: RemoteHost.endpoint(hostUrl, 'vm/$id', token),
      mode: result['mode'] as String? ?? config.mode.name,
      supportsRestart: result['supportsRestart'] == true,
      logs: logs.stream,
      exitCode: exited.future,
      onStop: () async {
        try {
          await host.call('app.stop', {'appId': id});
          onStopped?.call(id);
          await exited.future.timeout(stopTimeout);
        } on TimeoutException {
          // The host has stopped it; its exit notice was just not seen.
        } on RemoteHostException {
          // The host stops what a lost client started once its grace period ends.
        } on HostError catch (e) {
          throw LaunchException(e.message);
        }
      },
      onRestart: () => host.launchCall('app.restart', {'appId': id}),
    );
  }
}
