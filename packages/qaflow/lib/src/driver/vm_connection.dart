import 'dart:async';
import 'dart:convert';

import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../launch/launched_app.dart';
import 'transport.dart';

typedef VmConnector = Future<VmService> Function(String wsUri);

class VmConnection implements QaTransport {
  VmConnection._(this.service, this.callTimeout);

  final VmService service;

  /// How long one ext.qa.* call may take on top of any `timeoutMs` or
  /// `durationMs` it asks for. The agent bounds its own waits, so running
  /// past this means the app's UI isolate is not answering at all (frozen,
  /// or paused in a debugger). The error carries `rpcCode`, so the runner
  /// treats it as infrastructure: it ends the run, writes the reports and
  /// stops the app, and no action is left running against a failed step.
  final Duration callTimeout;

  static const Duration defaultCallTimeout = Duration(seconds: 60);
  String? _isolateId;
  final _logs = StreamController<String>.broadcast();
  late final StreamSubscription<Event> _isolateSub;
  late final StreamSubscription<Event> _stdoutSub;
  late final StreamSubscription<Event> _stderrSub;

  static Future<VmConnection> connect(
    Uri wsUri, {
    VmConnector? connector,
    Duration timeout = const Duration(seconds: 30),
    Duration retryInterval = const Duration(milliseconds: 250),
    Future<void>? giveUpWhen,
    Duration callTimeout = defaultCallTimeout,
  }) async {
    final connect = connector ?? vmServiceConnectUri;
    final deadline = DateTime.now().add(timeout);
    // Flipped as soon as giveUpWhen fires (typically the launched app's
    // exitCode future), so a dead process is not retried against for the
    // rest of the timeout. The caller registers its own listener on the
    // same future before calling connect(), so by the time this one runs
    // the caller already knows why (see QaSession.start).
    var gaveUp = false;
    if (giveUpWhen != null) {
      unawaited(giveUpWhen.then((_) => gaveUp = true));
    }
    Object? lastError;
    while (!gaveUp && DateTime.now().isBefore(deadline)) {
      VmService? service;
      try {
        service = await connect(wsUri.toString());
        final connection = VmConnection._(service, callTimeout);
        await connection._init();
        return connection;
      } catch (e) {
        lastError = e;
        // A connection may have been made even though _init (isolate
        // discovery, stream subscriptions) failed; dispose it so a retry
        // does not leak the socket.
        if (service != null) {
          await service.dispose();
        }
        if (gaveUp) break;
        // Race the delay against giveUpWhen so a process that dies mid-wait
        // is noticed within milliseconds instead of waiting out the full
        // retryInterval.
        await Future.any<void>([Future<void>.delayed(retryInterval), ?giveUpWhen]);
      }
    }
    if (gaveUp) {
      throw LaunchException('the app process exited while connecting to the VM service at ${redactUri(wsUri)}');
    }
    throw LaunchException(
      'could not connect to the VM service at ${redactUri(wsUri)} within $timeout '
      '(last error: ${redactToken('$lastError', wsUri)}) -- release builds have no VM service and cannot be driven.',
    );
  }

  Future<void> _init() async {
    await service.streamListen(EventStreams.kIsolate);
    await service.streamListen(EventStreams.kStdout);
    await service.streamListen(EventStreams.kStderr);
    _isolateSub = service.onIsolateEvent.listen(_onIsolateEvent);
    _stdoutSub = service.onStdoutEvent.listen((e) => _logs.add(_decodeBytes(e)));
    _stderrSub = service.onStderrEvent.listen((e) => _logs.add(_decodeBytes(e)));
    _isolateId = await _findAgentIsolate();
  }

  static String _decodeBytes(Event e) => e.bytes == null ? '' : utf8.decode(base64Decode(e.bytes!)).trimRight();

  Stream<String> get logs => _logs.stream;

  void _onIsolateEvent(Event event) {
    if (event.kind == EventKind.kServiceExtensionAdded && event.extensionRPC == QaMethod.ping.extensionName) {
      _isolateId = event.isolate?.id;
    } else if (event.kind == EventKind.kIsolateExit && event.isolate?.id == _isolateId) {
      _isolateId = null;
    }
  }

  Future<String?> _findAgentIsolate() async {
    final vm = await service.getVM();
    for (final ref in vm.isolates ?? const <IsolateRef>[]) {
      final isolate = await service.getIsolate(ref.id!);
      if (isolate.extensionRPCs?.contains(QaMethod.ping.extensionName) ?? false) {
        return ref.id;
      }
    }
    return null;
  }

  Future<String> _requireIsolate({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final id = _isolateId ?? await _findAgentIsolate();
      if (id != null) return _isolateId = id;
      if (DateTime.now().isAfter(deadline)) {
        throw QaException(QaErrorCode.notReady, 'no isolate exposes ${QaMethod.ping.extensionName}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) {
    final limit = _limitFor(args);
    return _call(method, args).timeout(
      limit,
      onTimeout: () {
        final seconds = (limit.inMilliseconds / 1000).toStringAsFixed(1);
        throw QaException(
          QaErrorCode.internal,
          'the app did not answer ${method.extensionName} within $seconds s; '
          'its UI isolate may be frozen or paused in a debugger',
          details: {'rpcCode': null, 'rpcMessage': 'no response within $seconds s'},
        );
      },
    );
  }

  Duration _limitFor(Map<String, Object?> args) {
    var requestedMs = 0;
    for (final key in const ['timeoutMs', 'durationMs']) {
      final value = args[key];
      if (value is num && value > requestedMs) requestedMs = value.toInt();
    }
    return callTimeout + Duration(milliseconds: requestedMs);
  }

  Future<QaResponse> _call(QaMethod method, Map<String, Object?> args) async {
    final isolateId = await _requireIsolate();
    final response = await _callExtension(method, isolateId, args);
    final qa = QaResponse.fromJson(response.json!.cast<String, Object?>());
    if (!qa.ok) {
      throw QaException(qa.code!, qa.message ?? 'unknown agent error', details: qa.details);
    }
    return qa;
  }

  /// Calls the extension, translating VM-service-level failures (as opposed
  /// to an ext.qa.* response with `ok: false`) into QaException so callers
  /// only ever have to catch one exception type. dispose() completes
  /// in-flight requests with an RPCError, and a dying/restarting isolate
  /// surfaces as an RPCError or a SentinelException rather than a normal
  /// response.
  Future<Response> _callExtension(QaMethod method, String isolateId, Map<String, Object?> args) async {
    try {
      return await service.callServiceExtension(
        method.extensionName,
        isolateId: isolateId,
        args: {'args': jsonEncode(args)},
      );
    } on SentinelException catch (e) {
      // The isolate the response refers to is gone, e.g. mid hot-restart.
      _isolateId = null;
      throw QaException(QaErrorCode.notReady, e.toString(), details: {'rpcCode': null, 'rpcMessage': e.toString()});
    } on RPCError catch (e) {
      // kMethodNotFound: the extension is not registered yet on the new
      // isolate (the hot-restart window). kIsolateMustBeRunnable: the
      // isolate exists but has not resumed yet. Both are transient and the
      // driver retries not_ready, so drop the cached isolate id and let the
      // next call re-discover it via _findAgentIsolate.
      final notReady =
          e.code == RPCErrorKind.kMethodNotFound.code || e.code == RPCErrorKind.kIsolateMustBeRunnable.code;
      if (notReady) _isolateId = null;
      throw QaException(
        notReady ? QaErrorCode.notReady : QaErrorCode.internal,
        e.message,
        details: {'rpcCode': e.code, 'rpcMessage': e.message},
      );
    }
  }

  Future<void> dispose() async {
    // Cancel the event subscriptions before touching _logs: an event that
    // was already in flight when dispose() was called must not reach
    // _logs.add after _logs.close(), which would throw.
    await _isolateSub.cancel();
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    await service.dispose();
    await _logs.close();
  }
}
