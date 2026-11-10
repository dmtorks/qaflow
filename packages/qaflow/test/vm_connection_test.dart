import 'dart:async';
import 'dart:convert';

import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fake_vm_service.dart';

void main() {
  test('selects the isolate that exposes ext.qa.ping', () async {
    final fake = FakeVmService(
      isolates: {
        'iso-helper': ['ext.other'],
        'iso-main': ['ext.qa.ping', 'ext.qa.tap'],
      },
    );
    fake.responder = (m, a) => QaResponse.success({'echo': a}).toJson();
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    final r = await conn.call(QaMethod.tap, {
      'selector': {'text': 'OK'},
    });
    expect(r.ok, isTrue);
    expect(fake.calls.single.$2, 'iso-main');
    expect(fake.calls.single.$1, 'ext.qa.tap');
    expect(fake.streamsListened, containsAll(['Isolate', 'Stdout', 'Stderr']));
  });

  test('error responses become QaException', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) => QaResponse.failure(QaErrorCode.notFound, 'nope', {'k': 1}).toJson();
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    await expectLater(
      conn.call(QaMethod.find, {
        'selector': {'text': 'x'},
      }),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.notFound)
            .having((e) => e.details['k'], 'details', 1),
      ),
    );
  });

  test('retries the connector until the timeout', () async {
    var attempts = 0;
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    final conn = await VmConnection.connect(
      Uri.parse('ws://x'),
      connector: (_) async {
        if (++attempts < 3) throw Exception('refused');
        return fake;
      },
      retryInterval: const Duration(milliseconds: 5),
    );
    addTearDown(conn.dispose);
    expect(attempts, 3);
    expect(conn, isNotNull);
  });

  test('gives up with a message mentioning release builds', () async {
    await expectLater(
      VmConnection.connect(
        Uri.parse('ws://x'),
        connector: (_) async => throw Exception('refused'),
        timeout: const Duration(milliseconds: 20),
        retryInterval: const Duration(milliseconds: 5),
      ),
      throwsA(isA<LaunchException>().having((e) => e.message, 'message', contains('release'))),
    );
  });

  test('follows the agent to a new isolate after hot restart', () async {
    final fake = FakeVmService(
      isolates: {
        'iso-1': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) => QaResponse.success({}).toJson();
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    fake.isolateEvents.add(
      Event(
        kind: EventKind.kIsolateExit,
        isolate: IsolateRef(id: 'iso-1'),
        timestamp: 0,
      ),
    );
    fake.isolates.remove('iso-1');
    fake.isolates['iso-2'] = ['ext.qa.ping'];
    fake.isolateEvents.add(
      Event(
        kind: EventKind.kServiceExtensionAdded,
        isolate: IsolateRef(id: 'iso-2'),
        extensionRPC: 'ext.qa.ping',
        timestamp: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await conn.call(QaMethod.ping, {});
    expect(fake.calls.last.$2, 'iso-2');
  });

  test('a Sentinel response becomes not_ready and clears the cached isolate', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) =>
        throw SentinelException.parse(m, {'kind': 'Collected', 'valueAsString': 'isolate is gone'});
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    await expectLater(
      conn.call(QaMethod.ping, {}),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.notReady)
            .having((e) => e.details['rpcCode'], 'rpcCode', isNull),
      ),
    );
  });

  test('RPCError kMethodNotFound becomes not_ready (extension not registered yet)', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) =>
        throw RPCError(m, RPCErrorKind.kMethodNotFound.code, RPCErrorKind.kMethodNotFound.message);
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    await expectLater(
      conn.call(QaMethod.ping, {}),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.notReady)
            .having((e) => e.details['rpcCode'], 'rpcCode', RPCErrorKind.kMethodNotFound.code),
      ),
    );
  });

  test('RPCError kIsolateMustBeRunnable becomes not_ready', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) =>
        throw RPCError(m, RPCErrorKind.kIsolateMustBeRunnable.code, RPCErrorKind.kIsolateMustBeRunnable.message);
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    await expectLater(
      conn.call(QaMethod.ping, {}),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.notReady)
            .having((e) => e.details['rpcCode'], 'rpcCode', RPCErrorKind.kIsolateMustBeRunnable.code),
      ),
    );
  });

  test('RPCError kConnectionDisposed becomes internal', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) =>
        throw RPCError(m, RPCErrorKind.kConnectionDisposed.code, RPCErrorKind.kConnectionDisposed.message);
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    await expectLater(
      conn.call(QaMethod.ping, {}),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.internal)
            .having((e) => e.details['rpcCode'], 'rpcCode', RPCErrorKind.kConnectionDisposed.code),
      ),
    );
  });

  test('RPCError kServiceDisappeared becomes internal', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    fake.responder = (m, a) =>
        throw RPCError(m, RPCErrorKind.kServiceDisappeared.code, RPCErrorKind.kServiceDisappeared.message);
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);
    await expectLater(
      conn.call(QaMethod.ping, {}),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.internal)
            .having((e) => e.details['rpcCode'], 'rpcCode', RPCErrorKind.kServiceDisappeared.code),
      ),
    );
  });

  test('a not_ready RPC failure makes the next call re-discover the isolate', () async {
    final fake = FakeVmService(
      isolates: {
        'iso-1': ['ext.qa.ping'],
      },
    );
    var first = true;
    fake.responder = (m, a) {
      if (first) {
        first = false;
        throw RPCError(m, RPCErrorKind.kIsolateMustBeRunnable.code, RPCErrorKind.kIsolateMustBeRunnable.message);
      }
      return QaResponse.success({}).toJson();
    };
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    addTearDown(conn.dispose);

    await expectLater(
      conn.call(QaMethod.ping, {}),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notReady)),
    );

    // The isolate changed underneath (e.g. a hot restart) between the
    // failed call and the retry, the way the driver's own retry loop would
    // encounter it. The cached isolate id must have been dropped so this
    // call re-resolves it instead of reusing the stale iso-1.
    fake.isolates.remove('iso-1');
    fake.isolates['iso-2'] = ['ext.qa.ping'];

    final r = await conn.call(QaMethod.ping, {});
    expect(r.ok, isTrue);
    expect(fake.calls.last.$2, 'iso-2');
  });

  test('dispose is safe when a stdout event is in flight', () async {
    final fake = FakeVmService(
      isolates: {
        'iso': ['ext.qa.ping'],
      },
    );
    final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
    // Emitted with no await in between, so the event's delivery to the
    // logs listener is still pending (scheduled but not yet run) when
    // dispose() starts. A dispose() that closed _logs before cancelling
    // the subscription would let this delivery crash with "Cannot add
    // event after closing"; the assertion here is simply that dispose()
    // completes without throwing.
    fake.stdoutEvents.add(
      Event(kind: EventKind.kWriteEvent, bytes: base64Encode(utf8.encode('late output')), timestamp: 0),
    );
    await conn.dispose();
  });

  group('call time limit', () {
    Future<(FakeVmService, VmConnection)> connected({required Duration callTimeout}) async {
      final fake = FakeVmService(
        isolates: {
          'iso': ['ext.qa.ping'],
        },
      )..responder = (m, a) => QaResponse.success({}).toJson();
      final conn = await VmConnection.connect(
        Uri.parse('ws://x'),
        connector: (_) async => fake,
        callTimeout: callTimeout,
      );
      addTearDown(conn.dispose);
      return (fake, conn);
    }

    test('a call the app never answers fails as an infrastructure error', () async {
      final (fake, conn) = await connected(callTimeout: const Duration(milliseconds: 50));
      fake.beforeReply = (_) => Completer<void>().future;
      await expectLater(
        conn.call(QaMethod.tap, {
          'selector': {'text': 'OK'},
        }),
        throwsA(
          isA<QaException>()
              .having((e) => e.code, 'code', QaErrorCode.internal)
              .having((e) => e.message, 'message', contains('did not answer ext.qa.tap within'))
              .having((e) => e.details.containsKey('rpcCode'), 'details has rpcCode', isTrue),
        ),
      );
    });

    test('the limit grows by the timeoutMs or durationMs the call asks for', () async {
      final (fake, conn) = await connected(callTimeout: const Duration(milliseconds: 50));
      fake.beforeReply = (_) => Future<void>.delayed(const Duration(milliseconds: 150));
      expect((await conn.call(QaMethod.waitForIdle, {'timeoutMs': 200})).ok, isTrue);
      expect((await conn.call(QaMethod.drag, {'durationMs': 200})).ok, isTrue);
      await expectLater(conn.call(QaMethod.ping, {}), throwsA(isA<QaException>()));
    });

    test('defaults to 60 seconds', () async {
      final fake = FakeVmService(
        isolates: {
          'iso': ['ext.qa.ping'],
        },
      );
      final conn = await VmConnection.connect(Uri.parse('ws://x'), connector: (_) async => fake);
      addTearDown(conn.dispose);
      expect(conn.callTimeout, const Duration(seconds: 60));
    });
  });
}
