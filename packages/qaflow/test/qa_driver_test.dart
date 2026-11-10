import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

/// Answers each method from a queue; an entry that is a QaException is thrown.
class ScriptedTransport implements QaTransport {
  final Map<QaMethod, List<Object>> script = {};
  final List<QaMethod> calls = [];
  final List<Map<String, Object?>> sent = [];

  void queue(QaMethod m, Object response) => script.putIfAbsent(m, () => []).add(response);

  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) async {
    sent.add(args);
    calls.add(method);
    if (method == QaMethod.waitForIdle) {
      final queue = script[method];
      if (queue == null || queue.isEmpty) return QaResponse.success({'settled': 'idle'});
      final next = queue.removeAt(0);
      if (next is QaException) throw next;
      return QaResponse.success(next as Map<String, Object?>);
    }
    if (method == QaMethod.elements) return QaResponse.success({'nodes': []});
    final queue = script[method];
    if (queue == null || queue.isEmpty) throw StateError('no scripted response for $method');
    final next = queue.removeAt(0);
    if (next is QaException) throw next;
    return QaResponse.success(next as Map<String, Object?>);
  }
}

Map<String, Object?> node({bool visible = true}) => {
  'node': QaNode(
    nodeId: 1,
    parentId: null,
    type: 'Text',
    text: 'OK',
    key: null,
    semanticsId: null,
    label: null,
    rect: const QaRect(0, 0, 10, 10),
    viewId: 0,
    visible: visible,
    interactive: false,
    enabled: true,
  ).toJson(),
};

void main() {
  late ScriptedTransport t;
  late QaDriver d;

  setUp(() {
    t = ScriptedTransport();
    d = QaDriver(t, stepTimeout: const Duration(milliseconds: 400), pollInterval: const Duration(milliseconds: 10));
  });

  test('back, hideKeyboard and setOrientation call the agent and settle', () async {
    t.queue(QaMethod.back, {'popped': true});
    t.queue(QaMethod.hideKeyboard, {'hadFocus': true});
    t.queue(QaMethod.setOrientation, {'orientation': 'landscapeLeft'});

    expect(await d.back(), isTrue);
    expect(await d.hideKeyboard(), isTrue);
    await d.setOrientation('landscapeLeft');

    expect(t.calls, [
      QaMethod.waitForIdle,
      QaMethod.back,
      QaMethod.hideKeyboard,
      QaMethod.waitForIdle,
      QaMethod.setOrientation,
      QaMethod.waitForIdle,
    ]);
    expect(t.sent[t.calls.indexOf(QaMethod.setOrientation)], {'orientation': 'landscapeLeft'});
  });

  test('tap retries retryable codes and settles before each attempt', () async {
    t.queue(QaMethod.tap, QaException(QaErrorCode.notFound, 'no'));
    t.queue(QaMethod.tap, QaException(QaErrorCode.obscured, 'covered'));
    t.queue(QaMethod.tap, node());
    final n = await d.tap(const Selector(text: 'OK'));
    expect(n.text, 'OK');
    expect(t.calls.where((c) => c == QaMethod.tap).length, 3);
    expect(t.calls.where((c) => c == QaMethod.waitForIdle).length, 3);
    expect(t.calls.first, QaMethod.waitForIdle);
  });

  test('bad_request is not retried', () async {
    t.queue(QaMethod.tap, QaException(QaErrorCode.badRequest, 'nope'));
    await expectLater(d.tap(const Selector(text: 'x')), throwsA(isA<QaException>()));
    expect(t.calls.where((c) => c == QaMethod.tap).length, 1);
  });

  test('gives up after the step timeout with the last error and a snapshot', () async {
    for (var i = 0; i < 100; i++) {
      t.queue(QaMethod.tap, QaException(QaErrorCode.notFound, 'still no'));
    }
    await expectLater(
      d.tap(const Selector(text: 'x')),
      throwsA(
        isA<QaStepFailure>()
            .having((f) => f.last.code, 'code', QaErrorCode.notFound)
            .having((f) => f.label, 'label', contains('tap'))
            .having((f) => f.snapshot, 'snapshot', isNotNull),
      ),
    );
  });

  test('assertVisible waits until a visible match appears', () async {
    t.queue(QaMethod.find, {'nodes': []});
    t.queue(QaMethod.find, {
      'nodes': [node(visible: false)['node']],
    });
    t.queue(QaMethod.find, {
      'nodes': [node()['node']],
    });
    await d.assertVisible(const Selector(text: 'OK'));
    expect(t.calls.where((c) => c == QaMethod.find).length, 3);
  });

  test('assertNotVisible waits until matches disappear', () async {
    t.queue(QaMethod.find, {
      'nodes': [node()['node']],
    });
    t.queue(QaMethod.find, {'nodes': []});
    await d.assertNotVisible(const Selector(text: 'OK'));
    expect(t.calls.where((c) => c == QaMethod.find).length, 2);
  });

  test('_retry retries when waitForIdle raises a retryable QaException', () async {
    // waitForIdle runs before every attempt (spec 8.3); a retryable error
    // there (e.g. not_ready mid hot restart) must be retried like any
    // retryable error from the attempt itself, not abort the step.
    t.queue(QaMethod.waitForIdle, QaException(QaErrorCode.notReady, 'not ready yet'));
    t.queue(QaMethod.tap, node());
    final n = await d.tap(const Selector(text: 'OK'));
    expect(n.text, 'OK');
    expect(t.calls.where((c) => c == QaMethod.tap).length, 1);
    expect(t.calls.where((c) => c == QaMethod.waitForIdle).length, 2);
  });

  test('pressKey and enterText pass their arguments through', () async {
    t.queue(QaMethod.pressKey, {'delivered': true, 'hadFocus': true, 'submitted': false});
    t.queue(QaMethod.enterText, {'node': null, 'value': 'abc'});
    await d.pressKey('mod+a');
    expect(await d.enterText('abc'), 'abc');
  });

  test('doubleTap sends count 2 after settling', () async {
    t.queue(QaMethod.tap, node());
    await d.doubleTap(const Selector(text: 'OK'));
    expect(t.calls, [QaMethod.waitForIdle, QaMethod.tap]);
    expect(t.sent.last['count'], 2);
  });

  test('coordinate helpers send x and y and neither settle nor retry', () async {
    t.queue(QaMethod.tap, {'node': null});
    t.queue(QaMethod.longPress, {'node': null});
    t.queue(QaMethod.drag, {'node': null});
    t.queue(QaMethod.scroll, {'node': null});
    await d.tapAt(10, 20, count: 2);
    await d.longPressAt(1, 2);
    await d.dragAt(3, 4, dx: 5, dy: 6, durationMs: 400);
    await d.scrollAt(7, 8, dy: 90);
    expect(t.calls, [QaMethod.tap, QaMethod.longPress, QaMethod.drag, QaMethod.scroll]);
    expect(t.sent[0], {'x': 10.0, 'y': 20.0, 'count': 2});
    expect(t.sent[1], {'x': 1.0, 'y': 2.0});
    expect(t.sent[2], {'x': 3.0, 'y': 4.0, 'dx': 5.0, 'dy': 6.0, 'durationMs': 400});
    expect(t.sent[3], {'x': 7.0, 'y': 8.0, 'dx': 0.0, 'dy': 90.0});
  });

  test('resetState is sent once and not retried', () async {
    t.queue(QaMethod.resetState, QaException(QaErrorCode.unsupported, 'no hook'));
    await expectLater(d.resetState(), throwsA(isA<QaException>()));
    expect(t.calls.where((c) => c == QaMethod.resetState).length, 1);
  });

  test('assertVisible honours a per-call timeout', () async {
    for (var i = 0; i < 1000; i++) {
      t.queue(QaMethod.find, {'nodes': []});
    }
    final watch = Stopwatch()..start();
    await expectLater(
      d.assertVisible(const Selector(text: 'never'), timeout: const Duration(milliseconds: 50)),
      throwsA(isA<QaStepFailure>()),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 380)));
  });

  test('waitForIdle sends the requested timeout', () async {
    await d.waitForIdle(timeout: const Duration(milliseconds: 1234));
    expect(t.sent.last['timeoutMs'], 1234);
  });

  test('elementAt returns the node and its selector candidates, and is not retried', () async {
    const button = QaNode(
      nodeId: 7,
      parentId: 2,
      type: 'ElevatedButton',
      text: null,
      key: 'login',
      semanticsId: null,
      label: null,
      rect: QaRect(100, 20, 80, 40),
      viewId: 0,
      visible: true,
      interactive: true,
      enabled: true,
      visibleRect: QaRect(100, 20, 80, 40),
    );
    t.queue(QaMethod.elementAt, {
      'node': button.toJson(),
      'selectors': [const Selector(id: 'login').toJson(), const Selector(type: 'ElevatedButton', index: 0).toJson()],
    });
    final hit = await d.elementAt(120, 40);
    expect(hit.node.key, 'login');
    expect(hit.selectors, [const Selector(id: 'login'), const Selector(type: 'ElevatedButton', index: 0)]);
    expect(t.sent.last, {'x': 120.0, 'y': 40.0});
    expect(t.calls, [QaMethod.elementAt], reason: 'no settle and no retry');

    t.queue(QaMethod.elementAt, QaException(QaErrorCode.notFound, 'nothing interesting at 1.0,1.0'));
    await expectLater(
      d.elementAt(1, 1),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notFound)),
    );
    expect(t.calls.where((c) => c == QaMethod.elementAt).length, 2);
  });
}
