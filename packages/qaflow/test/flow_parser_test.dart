import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' show loadYamlDocuments;

import 'flow_test_support.dart';

void main() {
  late TempFlows files;
  setUp(() => files = TempFlows());
  tearDown(() => files.dispose());

  Flow parse(String content, {String name = 'flow.yaml'}) => FlowParser().parseFile(files.write(name, content));

  Matcher parseError(int line, int column, String message) => throwsA(
    isA<FlowParseException>()
        .having((e) => e.line, 'line', line)
        .having((e) => e.column, 'column', column)
        .having((e) => e.message, 'message', contains(message)),
  );

  test('header and commands', () {
    final flow = parse('''
appId: com.example.ignored
name: Login works
tags: [smoke, login]
env:
  USER: alice
  RETRIES: 3
onFlowStart:
  - launchApp
onFlowComplete:
  - stopApp
---
- tapOn: Sign in
''');
    expect(flow.name, 'Login works');
    expect(flow.header.tags, ['smoke', 'login']);
    expect(flow.header.env, {'USER': 'alice', 'RETRIES': '3'});
    expect(flow.header.onFlowStart.single, isA<LaunchApp>());
    expect(flow.header.onFlowComplete.single, isA<StopApp>());
    expect((flow.commands.single as Tap).selector!.text, 'Sign in');
    expect(flow.commands.single.source.line, 12);
  });

  test('a single command list has an empty header and is named by its file', () {
    final flow = parse('- scroll\n', name: 'just_scroll.yaml');
    expect(flow.name, 'just_scroll');
    expect(flow.commands.single, isA<Scroll>());
  });

  test('every supported command form', () {
    files.write('sub/login.yaml', '- inputText: hi\n');
    final flow = parse('''
- launchApp
- launchApp:
    clearState: true
    stopApp: false
    label: Fresh start
- stopApp
- killApp
- clearState
- tapOn:
    id: go
    index: 1
    enabled: true
    childOf:
      type: Card
    optional: true
- tapOn:
    point: "50%, 25%"
- doubleTapOn: Item
- longPressOn:
    text: Item
- hover:
    id: open_dialog
- inputText: \${USER}
- eraseText
- eraseText: 3
- setText:
    element:
      id: password
    text: secret
- pressKey: mod+a
- assertVisible: Welcome
- assertNotVisible:
    text: Error
- extendedWaitUntil:
    visible: Done
    timeout: 15000
- waitForAnimationToEnd
- waitForAnimationToEnd:
    timeout: 800
- scroll
- scrollUntilVisible:
    element: Item 150
    direction: UP
    timeout: 5000
    visibilityPercentage: 50
    centerElement: true
    speed: 70
    scrollable:
      id: item_list
- swipe:
    direction: LEFT
    duration: 900
- swipe:
    start: 90%, 50%
    end: 10%, 50%
- swipe:
    from:
      id: card
    direction: UP
- takeScreenshot: after login
- takeScreenshot:
    path: nested/shot
- runFlow: sub/login.yaml
- runFlow:
    when:
      visible: Allow
      platform: macos
      true: \${FLAG}
    env:
      USER: bob
    commands:
      - tapOn: Allow
- repeat:
    times: 2
    while:
      notVisible: Done
    commands:
      - scroll
''');
    final c = flow.commands;
    expect(c.length, 30);
    expect((c[1] as LaunchApp).clearState, isTrue);
    expect((c[1] as LaunchApp).stopApp, isFalse);
    expect(c[1].title, 'Fresh start');
    expect((c[3] as StopApp).name, 'killApp');
    expect(c[4], isA<ClearState>());
    final tap = c[5] as Tap;
    expect(tap.optional, isTrue);
    expect(tap.selector!.id, 'go');
    expect(tap.selector!.index, 1);
    expect(tap.selector!.enabled, isTrue);
    expect(tap.selector!.childOf!.type, 'Card');
    expect((c[6] as Tap).point.toString(), '50%, 25%');
    expect((c[7] as Tap).kind, TapKind.doubleTap);
    expect((c[8] as Tap).kind, TapKind.longPress);
    expect((c[10] as InputText).text, '\${USER}');
    expect((c[11] as EraseText).count, 50);
    expect((c[12] as EraseText).count, 3);
    expect((c[13] as SetText).text, 'secret');
    expect((c[17] as ExtendedWaitUntil).timeoutMs, 15000);
    expect((c[18] as WaitForAnimationToEnd).timeoutMs, 5000);
    expect((c[19] as WaitForAnimationToEnd).timeoutMs, 800);
    final suv = c[21] as ScrollUntilVisible;
    expect(suv.direction, Direction.up);
    expect(suv.visibilityPercentage, 50);
    expect(suv.centerElement, isTrue);
    expect(suv.scrollable!.id, 'item_list');
    expect((c[22] as Swipe).durationMs, 900);
    expect((c[23] as Swipe).start.toString(), '90%, 50%');
    expect((c[24] as Swipe).from!.id, 'card');
    expect((c[25] as TakeScreenshot).fileName, 'after login');
    expect((c[26] as TakeScreenshot).fileName, 'nested/shot');
    expect((c[27] as RunFlow).subflow!.commands.single, isA<InputText>());
    final inline = c[28] as RunFlow;
    expect(inline.when!.platform, 'macOS');
    expect(inline.when!.isTrue, '\${FLAG}');
    expect(inline.env, {'USER': 'bob'});
    expect(inline.commands!.single, isA<Tap>());
    final rep = c[29] as Repeat;
    expect(rep.times, 2);
    expect(rep.whileCondition!.notVisible!.text, 'Done');
  });

  test('assertScreenshot', () {
    final c = parse('''
- assertScreenshot: login
- assertScreenshot:
    name: dialog-open
    threshold: 0.5
    ignore:
      - id: clock
      - "Last updated.*"
    label: Dialog
    optional: true
''').commands;
    final a = c[0] as AssertScreenshot;
    expect(a.screenshotName, 'login');
    expect(a.threshold, 0.1);
    expect(a.ignore, isEmpty);
    expect(a.title, 'assertScreenshot login');
    final b = c[1] as AssertScreenshot;
    expect(b.screenshotName, 'dialog-open');
    expect(b.threshold, 0.5);
    expect(b.ignore.map((s) => s.id ?? s.text), ['clock', 'Last updated.*']);
    expect(b.title, 'Dialog');
    expect(b.optional, isTrue);
  });

  test('assertScreenshot problems', () {
    expect(() => parse('- assertScreenshot\n'), parseError(1, 3, 'assertScreenshot needs a name'));
    expect(() => parse('- assertScreenshot:\n    threshold: 1\n'), parseError(2, 5, 'assertScreenshot needs name'));
    expect(() => parse('- assertScreenshot: a/b\n'), parseError(1, 21, 'must use only letters, digits'));
    expect(
      () => parse('- assertScreenshot:\n    name: x\n    threshold: 101\n'),
      parseError(3, 16, 'threshold must be between 0 and 100'),
    );
    expect(
      () => parse('- assertScreenshot:\n    name: x\n    threshold: .nan\n'),
      parseError(3, 16, 'threshold must be between 0 and 100'),
    );
    expect(
      () => parse('- assertScreenshot:\n    name: x\n    ignore: clock\n'),
      parseError(3, 13, 'ignore must be a list of selectors'),
    );
    expect(
      () => parse('- assertScreenshot:\n    name: x\n    thresholdPercentage: 1\n'),
      parseError(3, 5, 'thresholdPercentage'),
    );
  });

  test('unsupported and unknown commands', () {
    expect(
      () => parse('- launchApp\n- setLocation:\n    latitude: 1\n'),
      parseError(2, 3, 'setLocation is not supported by QAFlow'),
    );
    expect(() => parse('- tapOnn: X\n'), parseError(1, 3, 'did you mean tapOn'));
    expect(() => parse('- inputRandomText\n'), parseError(1, 3, 'inputRandomText is not supported by QAFlow'));
  });

  test('mobile commands', () {
    final c = parse('''
- back
- back:
    label: Go back
    optional: true
- pressKey: Back
- hideKeyboard
- setOrientation: landscape
- setOrientation: LANDSCAPE_RIGHT
- setOrientation:
    orientation: PORTRAIT
    label: Upright
- openLink: demo://app/item/42
- openLink:
    link: \${BASE}/item/1
    autoVerify: true
    browser: false
''').commands;
    expect(c[0], isA<Back>().having((b) => b.title, 'title', 'back'));
    expect((c[1] as Back).label, 'Go back');
    expect(c[1].optional, isTrue);
    expect(c[2], isA<Back>().having((b) => b.title, 'title', 'pressKey back').having((b) => b.name, 'name', 'back'));
    expect(c[3], isA<HideKeyboard>());
    expect((c[4] as SetOrientation).orientation, ScreenOrientation.landscapeLeft);
    expect((c[5] as SetOrientation).orientation, ScreenOrientation.landscapeRight);
    expect((c[6] as SetOrientation).orientation, ScreenOrientation.portrait);
    expect(c[6].title, 'Upright');
    expect((c[7] as OpenLink).link, 'demo://app/item/42');
    expect((c[8] as OpenLink).link, '\${BASE}/item/1');
  });

  test('mobile command problems', () {
    expect(() => parse('- back: now\n'), parseError(1, 9, 'back takes no value'));
    expect(
      () => parse('- setOrientation: SIDEWAYS\n'),
      parseError(1, 19, 'orientation must be PORTRAIT, LANDSCAPE_LEFT or LANDSCAPE_RIGHT'),
    );
    expect(() => parse('- openLink: not a url\n'), parseError(1, 13, 'openLink needs an absolute URL with a scheme'));
    expect(() => parse('- openLink:\n    url: x\n'), parseError(2, 5, 'url'));
  });

  test('platform conditions accept iOS and Android', () {
    final c = parse('- runFlow:\n    when:\n      platform: ios\n    commands: [scroll]\n').commands;
    expect((c.single as RunFlow).when!.platform, 'iOS');
    expect(
      () => parse('- runFlow:\n    when:\n      platform: tvOS\n    commands: [scroll]\n'),
      parseError(3, 17, 'platform must be iOS, Android, macOS, Windows or Linux'),
    );
  });

  test('selector problems', () {
    expect(
      () => parse('- tapOn:\n    text: A\n    checked: true\n'),
      parseError(3, 5, 'selector field checked is not supported'),
    );
    expect(() => parse('- tapOn:\n    color: red\n'), parseError(2, 5, 'unknown selector field color'));
    expect(() => parse('- tapOn:\n    enabled: true\n'), parseError(2, 5, 'needs text, id, type or childOf'));
    expect(() => parse('- tapOn:\n    id: a\n    point: "1, 2"\n'), parseError(1, 3, 'point cannot be combined'));
    expect(
      () => parse('- tapOn:\n    text: A\n    repeat: 2\n'),
      parseError(3, 5, 'tapOn option repeat is not supported'),
    );
  });

  test('JavaScript expressions are rejected', () {
    expect(() => parse('- inputText: \${a + b}\n'), parseError(1, 14, 'JavaScript expressions are not supported'));
  });

  test('structural errors', () {
    expect(() => parse('- extendedWaitUntil:\n    visible: A\n'), parseError(1, 3, 'needs timeout'));
    expect(() => parse('- repeat:\n    commands:\n      - scroll\n'), parseError(1, 3, 'repeat needs times or while'));
    expect(
      () => parse('- swipe:\n    direction: LEFT\n    start: 1, 2\n    end: 3, 4\n'),
      parseError(1, 3, 'either direction or start and end'),
    );
    expect(() => parse('bogus: 1\n---\n- scroll\n'), parseError(1, 1, 'unknown header field bogus'));
    expect(() => parse('- tapOn: [unclosed\n'), throwsA(isA<FlowParseException>()));
  });

  test('an empty body after a multi-line header reports the position of the empty document', () {
    final content = 'appId: com.example\nname: Test\ntags: [a]\nenv: {}\n---\n';
    final path = files.write('empty_body.yaml', content);
    // The parser must report the empty second document's own span, not a
    // hardcoded 1:1 — derive the expected position the same way the parser
    // does, independent of which line the yaml package happens to pick.
    final expectedStart = loadYamlDocuments(content, sourceUrl: Uri.file(path)).last.contents.span.start;
    expect(
      () => FlowParser().parseFile(path),
      throwsA(
        isA<FlowParseException>()
            .having((e) => e.line, 'line', expectedStart.line + 1)
            .having((e) => e.line, 'line', greaterThan(1))
            .having((e) => e.column, 'column', expectedStart.column + 1)
            .having((e) => e.message, 'message', contains('the flow has no commands')),
      ),
    );
  });

  test('runFlow subflows: missing file, cycles and variable paths', () {
    expect(() => parse('- runFlow: nope.yaml\n'), parseError(1, 12, 'runFlow file not found'));
    files.write('b.yaml', '- runFlow: a.yaml\n');
    final a = files.write('a.yaml', '- runFlow: b.yaml\n');
    expect(
      () => FlowParser().parseFile(a),
      throwsA(isA<FlowParseException>().having((e) => e.message, 'message', contains('runFlow cycle'))),
    );
    final lazy = parse('- runFlow: \${WHICH}.yaml\n').commands.single as RunFlow;
    expect(lazy.subflow, isNull);
    expect(lazy.file, '\${WHICH}.yaml');
  });

  test('FlowParseException prints file:line:column: message', () {
    final e = FlowParseException('/x/f.yaml', 2, 3, 'boom');
    expect(e.toString(), '/x/f.yaml:2:3: boom');
  });

  group('parseText', () {
    test('parses text as the given file and reports errors against it', () {
      final path = p.join(files.dir, 'edited.yaml');
      final flow = FlowParser().parseText('name: Edited\n---\n- launchApp\n', path);
      expect(flow.file, path);
      expect(flow.name, 'Edited');
      expect(flow.commands.single, isA<LaunchApp>());
      expect(
        () => FlowParser().parseText('- launchApp\n- tapOn\n', path),
        throwsA(
          isA<FlowParseException>()
              .having((e) => e.file, 'file', path)
              .having((e) => e.line, 'line', 2)
              .having((e) => e.column, 'column', 3)
              .having((e) => e.message, 'message', 'tapOn needs a selector or a point'),
        ),
      );
    });

    test('relative runFlow files resolve against the folder of the path', () {
      files.write('sub/login.yaml', '- inputText: hi\n');
      final flow = FlowParser().parseText('- runFlow: sub/login.yaml\n', p.join(files.dir, 'main.yaml'));
      expect((flow.commands.single as RunFlow).subflow!.commands.single, isA<InputText>());
      expect(
        () => FlowParser().parseText('- runFlow: sub/login.yaml\n', p.join(files.dir, 'elsewhere', 'main.yaml')),
        parseError(1, 12, 'runFlow file not found'),
      );
    });

    test('the result is not cached, and a text that runs its own file is a cycle', () {
      final parser = FlowParser();
      final path = p.join(files.dir, 'self.yaml');
      expect(parser.parseText('- launchApp\n', path).commands, hasLength(1));
      expect(parser.parseText('- launchApp\n- scroll\n', path).commands, hasLength(2));
      files.write('self.yaml', '- launchApp\n');
      expect(() => parser.parseText('- runFlow: self.yaml\n', path), parseError(1, 12, 'runFlow cycle'));
    });
  });
}
