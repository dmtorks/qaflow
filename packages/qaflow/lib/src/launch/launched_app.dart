class LaunchException implements Exception {
  LaunchException(this.message);
  final String message;
  @override
  String toString() => 'LaunchException: $message';
}

/// [uri] with the value of its `token` query, which a QA host's proxied VM
/// service carries, replaced by `***`; for logs and error messages.
Uri redactUri(Uri uri) {
  if (!uri.queryParameters.containsKey('token')) return uri;
  final query = [
    for (final MapEntry(:key, :value) in uri.queryParametersAll.entries)
      for (final v in value) '${Uri.encodeQueryComponent(key)}=${key == 'token' ? '***' : Uri.encodeQueryComponent(v)}',
  ].join('&');
  return uri.replace(query: query);
}

/// [text] with [uri]'s token, plain or query-encoded, replaced by `***`.
String redactToken(String text, Uri uri) {
  final token = uri.queryParameters['token'];
  if (token == null || token.isEmpty) return text;
  return text.replaceAll(token, '***').replaceAll(Uri.encodeQueryComponent(token), '***');
}

abstract class AppLauncher {
  Future<LaunchedApp> start();
}

/// A running app under test, however it was launched.
class LaunchedApp {
  LaunchedApp({
    required this.appId,
    required this.wsUri,
    required this.mode,
    required this.supportsRestart,
    required this.logs,
    required this.exitCode,
    required this._onStop,
    this._onRestart,
  });

  final String? appId;
  final Uri wsUri;
  final String mode;
  final bool supportsRestart;
  final Stream<String> logs;
  final Future<int> exitCode;
  final Future<void> Function() _onStop;
  final Future<void> Function()? _onRestart;

  Future<void> stop() => _onStop();

  Future<void> restart() {
    final r = _onRestart;
    if (r == null || !supportsRestart) {
      throw LaunchException('hot restart is not supported for a $mode launch');
    }
    return r();
  }
}
