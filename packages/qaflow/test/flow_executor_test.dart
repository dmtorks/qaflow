import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  const src = SourceRef('f.yaml', 1, 1);
  const exec = CommandExecutor();
  late FakeAgent agent;
  late Directory shots;
  late QaDriver driver;

  setUp(() {
    agent = FakeAgent();
    shots = Directory.systemTemp.createTempSync('qa_shots');
    driver = testDriver(agent, shots.path);
  });
  tearDown(() => shots.deleteSync(recursive: true));

  ExecutionContext ctx([Map<String, String> vars = const {}]) => ExecutionContext(
    driver: driver,
    scope: VariableScope(vars),
    screenshotDir: shots.path,
    viewWidth: 800,
    viewHeight: 600,
  );

  Map<String, Object?> scrollable(QaRect visibleRect, {QaRect? rect}) =>
      fakeNode(type: 'Scrollable', rect: rect ?? visibleRect, visibleRect: visibleRect).toJson();

  group('toSelector', () {
    bool fullMatch(Selector s, String text) => RegExp('^(?:${s.textRegex})\$').hasMatch(text);

    test('text matches literally or as a full regular expression', () {
      final s = CommandExecutor.toSelector(const FlowSelector(text: 'Item (1)'), VariableScope());
      expect(s.text, isNull);
      expect(fullMatch(s, 'Item (1)'), isTrue);
      expect(fullMatch(s, 'Item 1'), isTrue);
      expect(fullMatch(s, 'Item 12'), isFalse);
    });

    test('an invalid regular expression falls back to a literal', () {
      final s = CommandExecutor.toSelector(const FlowSelector(text: 'Item (1'), VariableScope());
      expect(s.text, 'Item (1');
      expect(s.textRegex, isNull);
    });

    test('variables, childOf and the other fields carry over', () {
      final s = CommandExecutor.toSelector(
        const FlowSelector(
          id: '\${ID}',
          index: 2,
          enabled: false,
          type: 'TextButton',
          childOf: FlowSelector(type: 'AlertDialog'),
        ),
        VariableScope({'ID': 'ok'}),
      );
      expect(
        s,
        const Selector(
          id: 'ok',
          index: 2,
          enabled: false,
          type: 'TextButton',
          within: Selector(type: 'AlertDialog'),
        ),
      );
    });
  });

  test('tapOn a point settles, then taps at the resolved percentage', () async {
    await exec.execute(Tap(source: src, kind: TapKind.tap, point: PointSpec.tryParse('50%, 25%')), ctx());
    expect(agent.methods, [QaMethod.waitForIdle, QaMethod.tap]);
    expect(agent.argsFor(QaMethod.tap).single, {'x': 400.0, 'y': 150.0});
  });

  test('doubleTapOn a selector sends count 2', () async {
    await exec.execute(
      const Tap(
        source: src,
        kind: TapKind.doubleTap,
        selector: FlowSelector(id: 'row'),
      ),
      ctx(),
    );
    final args = agent.argsFor(QaMethod.tap).single;
    expect(args['count'], 2);
    expect(args['selector'], {'id': 'row'});
  });

  test('inputText substitutes variables', () async {
    await exec.execute(const InputText(source: src, text: 'hi \${USER}'), ctx({'USER': 'alice'}));
    expect(agent.argsFor(QaMethod.enterText).single['text'], 'hi alice');
  });

  test('scroll picks the largest visible scrollable and scrolls 70% of its height', () async {
    agent.on[QaMethod.elements] = (_) => {
      'nodes': [
        scrollable(const QaRect(0, 0, 200, 600)),
        scrollable(const QaRect(200, 0, 600, 600), rect: const QaRect(200, 0, 600, 5000)),
        fakeNode(type: 'Scrollable', rect: const QaRect(0, 0, 900, 900), visibleRect: null).toJson(),
      ],
    };
    await exec.execute(const Scroll(source: src), ctx());
    expect(agent.argsFor(QaMethod.scroll).single, {'x': 500.0, 'y': 300.0, 'dx': 0.0, 'dy': 420.0});
  });

  test('scrollUntilVisible scrolls half a viewport at a time until the element is fully visible', () async {
    agent.on[QaMethod.elements] = (_) => {
      'nodes': [scrollable(const QaRect(0, 0, 800, 600))],
    };
    var finds = 0;
    agent.on[QaMethod.find] = (_) {
      finds++;
      return {
        'nodes': finds < 3
            ? <Object?>[]
            : [
                fakeNode(
                  text: 'Item 150',
                  rect: const QaRect(0, 100, 800, 50),
                  visibleRect: const QaRect(0, 100, 800, 50),
                ).toJson(),
              ],
      };
    };
    await exec.execute(
      const ScrollUntilVisible(
        source: src,
        element: FlowSelector(text: 'Item 150'),
      ),
      ctx(),
    );
    final scrolls = agent.argsFor(QaMethod.scroll);
    expect(scrolls, hasLength(2));
    expect(scrolls.map((a) => a['dy']), everyElement(300.0));
    expect(agent.argsFor(QaMethod.waitForIdle), hasLength(1), reason: 'settles once, not between scrolls');
  });

  test('a named scrollable settles once to resolve it, not again on every scroll iteration', () async {
    var finds = 0;
    agent.on[QaMethod.find] = (args) {
      final selector = (args['selector'] as Map).cast<String, Object?>();
      if (selector['id'] == 'list') {
        return {
          'nodes': [scrollable(const QaRect(0, 0, 800, 600))],
        };
      }
      finds++;
      return {
        'nodes': finds < 4
            ? <Object?>[]
            : [
                fakeNode(
                  text: 'Item 150',
                  rect: const QaRect(0, 100, 800, 50),
                  visibleRect: const QaRect(0, 100, 800, 50),
                ).toJson(),
              ],
      };
    };
    await exec.execute(
      const ScrollUntilVisible(
        source: src,
        element: FlowSelector(text: 'Item 150'),
        scrollable: FlowSelector(id: 'list'),
      ),
      ctx(),
    );
    expect(agent.argsFor(QaMethod.scroll), hasLength(3));
    expect(
      agent.argsFor(QaMethod.waitForIdle),
      hasLength(2),
      reason: 'one explicit settle plus one to resolve the named scrollable via assertVisible, not once per scroll',
    );
  });

  test('visibilityPercentage decides when a partly visible element counts', () async {
    agent.on[QaMethod.elements] = (_) => {
      'nodes': [scrollable(const QaRect(0, 0, 800, 600))],
    };
    agent.on[QaMethod.find] = (_) => {
      'nodes': [
        fakeNode(
          text: 'Edge',
          rect: const QaRect(0, 580, 800, 40),
          visibleRect: const QaRect(0, 580, 800, 20),
        ).toJson(),
      ],
    };
    await exec.execute(
      const ScrollUntilVisible(
        source: src,
        element: FlowSelector(text: 'Edge'),
        visibilityPercentage: 50,
      ),
      ctx(),
    );
    expect(agent.argsFor(QaMethod.scroll), isEmpty);
    await expectLater(
      exec.execute(
        const ScrollUntilVisible(
          source: src,
          element: FlowSelector(text: 'Edge'),
          timeoutMs: 30,
        ),
        ctx(),
      ),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notFound)),
    );
    expect(agent.argsFor(QaMethod.scroll), isNotEmpty);
  });

  test('centerElement moves the element to the middle of the scrollable', () async {
    agent.on[QaMethod.elements] = (_) => {
      'nodes': [scrollable(const QaRect(0, 0, 800, 600))],
    };
    agent.on[QaMethod.find] = (_) => {
      'nodes': [
        fakeNode(text: 'Low', rect: const QaRect(0, 480, 800, 40), visibleRect: const QaRect(0, 480, 800, 40)).toJson(),
      ],
    };
    await exec.execute(
      const ScrollUntilVisible(
        source: src,
        element: FlowSelector(text: 'Low'),
        centerElement: true,
      ),
      ctx(),
    );
    expect(agent.argsFor(QaMethod.scroll).single, {'x': 400.0, 'y': 300.0, 'dx': 0.0, 'dy': 200.0});
  });

  test('swipe LEFT drags from 90% to 10% of the view', () async {
    await exec.execute(const Swipe(source: src, direction: Direction.left), ctx());
    expect(agent.argsFor(QaMethod.drag).single, {'x': 720.0, 'y': 300.0, 'dx': -640.0, 'dy': 0.0, 'durationMs': 400});
  });

  test('swipe from an element applies the direction to its rect', () async {
    agent.on[QaMethod.find] = (_) => {
      'nodes': [
        fakeNode(
          key: 'card',
          rect: const QaRect(100, 100, 200, 100),
          visibleRect: const QaRect(100, 100, 200, 100),
        ).toJson(),
      ],
    };
    await exec.execute(
      const Swipe(
        source: src,
        direction: Direction.up,
        from: FlowSelector(id: 'card'),
      ),
      ctx(),
    );
    expect(agent.argsFor(QaMethod.drag).single, {'x': 200.0, 'y': 150.0, 'dx': 0.0, 'dy': -40.0, 'durationMs': 400});
  });

  test('takeScreenshot writes a sanitised file name inside the folder', () async {
    final written = (await exec.execute(const TakeScreenshot(source: src, fileName: 'after login!'), ctx())).artifacts;
    expect(written.single, p.join(shots.path, 'after_login_.png'));
    expect(File(written.single).readAsBytesSync().take(4), [0x89, 0x50, 0x4E, 0x47]);
    await expectLater(
      exec.execute(const TakeScreenshot(source: src, fileName: '../escape'), ctx()),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.badRequest)),
    );
  });

  test('extendedWaitUntil uses its own timeout', () async {
    final watch = Stopwatch()..start();
    await expectLater(
      exec.execute(
        const ExtendedWaitUntil(
          source: src,
          visible: FlowSelector(text: 'never'),
          timeoutMs: 40,
        ),
        ctx(),
      ),
      throwsA(isA<QaStepFailure>()),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 280)));
  });

  group('mobile commands', () {
    late RecordingController device;
    setUp(() => device = RecordingController());

    ExecutionContext mobile([Map<String, String> vars = const {}]) => ExecutionContext(
      driver: driver,
      scope: VariableScope(vars),
      screenshotDir: shots.path,
      viewWidth: 400,
      viewHeight: 800,
      device: device,
    );

    test('back and hideKeyboard go to the agent', () async {
      await exec.execute(const Back(source: src), mobile());
      await exec.execute(const HideKeyboard(source: src), mobile());
      expect(agent.methods, containsAllInOrder([QaMethod.back, QaMethod.hideKeyboard]));
    });

    test('setOrientation goes to the device and settles', () async {
      await exec.execute(const SetOrientation(source: src, orientation: ScreenOrientation.landscapeLeft), mobile());
      expect(device.calls, ['orientation landscapeLeft']);
      expect(agent.methods.last, QaMethod.waitForIdle);
    });

    test('openLink substitutes variables, goes to the device, and tolerates a backgrounded app', () async {
      agent.on[QaMethod.waitForIdle] = (_) => throw QaException(QaErrorCode.notReady, 'lifecycle: paused');
      await exec.execute(const OpenLink(source: src, link: r'${BASE}/item/1'), mobile({'BASE': 'demo://app'}));
      expect(device.calls, ['link demo://app/item/1']);
    });

    test('on desktop they are unsupported', () async {
      await expectLater(
        exec.execute(const OpenLink(source: src, link: 'demo://x'), ctx()),
        throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.unsupported)),
      );
    });
  });

  test('lifecycle and composite commands belong to the runner', () async {
    await expectLater(exec.execute(const LaunchApp(source: src), ctx()), throwsStateError);
  });
}
