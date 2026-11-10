import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('parses modifiers and key, case-insensitive', () {
    final c = KeyChord.parse('Mod+Shift+A');
    expect(c.modifiers, ['mod', 'shift']);
    expect(c.key, 'a');
  });

  test('single key has no modifiers', () {
    expect(KeyChord.parse('enter').modifiers, isEmpty);
  });

  test('rejects unknown modifiers and empty parts', () {
    expect(() => KeyChord.parse('hyper+a'), throwsFormatException);
    expect(() => KeyChord.parse('ctrl+'), throwsFormatException);
  });

  test('namedKeys lists the special keys and each parses as a key', () {
    expect(
      KeyChord.namedKeys,
      containsAll([
        'enter',
        'tab',
        'escape',
        'space',
        'backspace',
        'delete',
        'arrowup',
        'arrowdown',
        'arrowleft',
        'arrowright',
        'home',
        'end',
        'pageup',
        'pagedown',
        'f1',
        'f12',
      ]),
    );
    for (final name in KeyChord.namedKeys) {
      expect(KeyChord.parse(name).key, name);
    }
  });
}
