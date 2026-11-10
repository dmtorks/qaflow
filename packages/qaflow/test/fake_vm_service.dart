import 'dart:async';
import 'dart:convert';

import 'package:test/fake.dart';
import 'package:vm_service/vm_service.dart';

class FakeVmService extends Fake implements VmService {
  FakeVmService({required this.isolates});

  /// isolate id -> extension RPC names
  final Map<String, List<String>> isolates;
  final isolateEvents = StreamController<Event>.broadcast();
  final stdoutEvents = StreamController<Event>.broadcast();
  final streamsListened = <String>[];
  final calls = <(String method, String isolateId, Map<String, dynamic>? args)>[];
  Map<String, Object?> Function(String method, Map<String, Object?> args)? responder;

  /// Awaited before an extension call answers; return a future that never
  /// completes to model an app whose UI isolate has stopped answering.
  Future<void> Function(String method)? beforeReply;
  int disposeCalls = 0;
  Object? disposeError;

  @override
  Future<VM> getVM() async => VM(
    isolates: [for (final id in isolates.keys) IsolateRef(id: id, name: id)],
  );

  @override
  Future<Isolate> getIsolate(String isolateId) async =>
      Isolate(id: isolateId, name: isolateId, extensionRPCs: isolates[isolateId]);

  @override
  Future<Success> streamListen(String streamId) async {
    streamsListened.add(streamId);
    return Success();
  }

  @override
  Stream<Event> get onIsolateEvent => isolateEvents.stream;
  @override
  Stream<Event> get onStdoutEvent => stdoutEvents.stream;
  @override
  Stream<Event> get onStderrEvent => const Stream.empty();

  @override
  Future<Response> callServiceExtension(String method, {String? isolateId, Map<String, dynamic>? args}) async {
    calls.add((method, isolateId!, args));
    await beforeReply?.call(method);
    final decoded = (jsonDecode(args!['args'] as String) as Map).cast<String, Object?>();
    // The real VM service adds a type field to extension results; mirror it.
    return Response.parse({'type': '_extensionType', ...responder!(method, decoded)})!;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (disposeError != null) throw disposeError!;
    await isolateEvents.close();
    await stdoutEvents.close();
  }
}
