import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  const writer = StepWriter();
  late TempFlows files;
  setUp(() => files = TempFlows());
  tearDown(() => files.dispose());

  Command readBack(String yaml) => FlowParser().parseText(yaml, p.join(files.dir, 'recorded.yaml')).commands.single;

  /// The parsed selector back in protocol form, for comparing with what was written.
  Selector back(FlowSelector f) => Selector(
    id: f.id,
    text: f.text,
    type: f.type,
    index: f.index,
    enabled: f.enabled,
    within: f.childOf == null ? null : back(f.childOf!),
  );

  test('launchApp', () {
    expect(writer.yamlFor(const RecordLaunchApp()), '- launchApp\n');
    expect(readBack('- launchApp\n'), isA<LaunchApp>());
  });

  test('tapOn with every selector shape reads back to the same selector', () {
    const shapes = [
      Selector(id: 'login'),
      Selector(text: 'Sign in'),
      Selector(type: 'TextField', index: 1),
      Selector(
        text: 'Sign in',
        within: Selector(id: 'form'),
      ),
      Selector(id: 'login', enabled: true),
      Selector(text: 'yes'),
      Selector(text: 'Item (1)', type: 'ListTile', index: 0),
    ];
    for (final s in shapes) {
      final yaml = writer.yamlFor(RecordTapOn(s));
      final tap = readBack(yaml) as Tap;
      expect(tap.kind, TapKind.tap, reason: yaml);
      expect(back(tap.selector!), s, reason: yaml);
    }
    expect(writer.yamlFor(const RecordTapOn(Selector(id: 'login'))), '- tapOn:\n    id: login\n');
    expect(
      writer.yamlFor(
        const RecordTapOn(
          Selector(
            text: 'Sign in',
            within: Selector(id: 'form'),
          ),
        ),
      ),
      '- tapOn:\n    text: Sign in\n    childOf:\n      id: form\n',
    );
  });

  test('inputText and pressKey quote what YAML would misread', () {
    const texts = [
      'alice',
      'yes',
      'true',
      '150',
      'a: b',
      '# not a comment',
      '- dash',
      'multi\nline',
      '',
      ' spaced ',
      'mod+shift+a',
      'émoji ✓',
      'say "hi"',
    ];
    for (final text in texts) {
      final yaml = writer.yamlFor(RecordInputText(text));
      expect((readBack(yaml) as InputText).text, text, reason: yaml);
    }
    expect(writer.yamlFor(const RecordInputText('alice')), '- inputText: alice\n');
    expect(writer.yamlFor(const RecordInputText('yes')), '- inputText: "yes"\n');
    expect(writer.yamlFor(const RecordInputText('150')), '- inputText: "150"\n');
    expect((readBack(writer.yamlFor(const RecordPressKey('enter'))) as PressKey).key, 'enter');
    expect((readBack(writer.yamlFor(const RecordPressKey('mod+shift+a'))) as PressKey).key, 'mod+shift+a');
  });

  test('back, hideKeyboard and setOrientation read back', () {
    expect(writer.yamlFor(const RecordBack()), '- back\n');
    expect(readBack('- back\n'), isA<Back>());
    expect(writer.yamlFor(const RecordHideKeyboard()), '- hideKeyboard\n');
    expect(readBack('- hideKeyboard\n'), isA<HideKeyboard>());
    for (final o in ScreenOrientation.values) {
      final yaml = writer.yamlFor(RecordSetOrientation(o));
      expect((readBack(yaml) as SetOrientation).orientation, o);
    }
    expect(
      writer.yamlFor(const RecordSetOrientation(ScreenOrientation.landscapeRight)),
      '- setOrientation: LANDSCAPE_RIGHT\n',
    );
  });

  test('scroll down is scroll; another direction is the swipe that reveals that side', () {
    expect(writer.yamlFor(const RecordScroll(Direction.down)), '- scroll\n');
    expect(readBack('- scroll\n'), isA<Scroll>());
    for (final (scroll, swipe) in [
      (Direction.up, Direction.down),
      (Direction.left, Direction.right),
      (Direction.right, Direction.left),
    ]) {
      final command = readBack(writer.yamlFor(RecordScroll(scroll))) as Swipe;
      expect(command.direction, swipe, reason: scroll.name);
    }
  });

  test('assertVisible', () {
    final a = readBack(writer.yamlFor(const RecordAssertVisible(Selector(id: 'login')))) as AssertVisible;
    expect(a.selector.id, 'login');
    expect(writer.yamlFor(const RecordAssertVisible(Selector(id: 'login'))), '- assertVisible:\n    id: login\n');
  });

  test('selectorFragment writes key and semanticsId as id and drops textRegex', () {
    expect(StepWriter.selectorFragment(const Selector(key: 'k')), 'id: k\n');
    expect(StepWriter.selectorFragment(const Selector(semanticsId: 's', textRegex: 'x')), 'id: s\n');
    expect(StepWriter.selectorFragment(const Selector(id: 'a'), indent: 2), '  id: a\n');
  });
}
