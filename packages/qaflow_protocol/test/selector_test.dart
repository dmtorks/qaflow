import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips every field through JSON', () {
    const s = Selector(
      text: 'OK',
      textRegex: 'O.',
      id: 'ok',
      key: 'k',
      semanticsId: 's',
      type: 'TextButton',
      index: 2,
      within: Selector(type: 'AlertDialog'),
    );
    final back = Selector.fromJson(s.toJson());
    expect(back, equals(s));
    expect(back.within, equals(const Selector(type: 'AlertDialog')));
  });

  test('omits null fields from JSON', () {
    expect(const Selector(text: 'a').toJson(), equals({'text': 'a'}));
  });

  test('isEmpty is true only when no field is set', () {
    expect(const Selector().isEmpty, isTrue);
    expect(const Selector(index: 0).isEmpty, isTrue);
    expect(const Selector(text: 'a').isEmpty, isFalse);
  });

  test('enabled round-trips and does not make a selector non-empty on its own', () {
    const s = Selector(text: 'Go', enabled: false);
    expect(Selector.fromJson(s.toJson()), equals(s));
    expect(s.toJson()['enabled'], false);
    expect(const Selector(enabled: true).isEmpty, isTrue);
  });
}
