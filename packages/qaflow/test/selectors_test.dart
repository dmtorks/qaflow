import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  QaNode node({String type = 'Text', String? text, String? key, String? semanticsId}) => QaNode(
    nodeId: 3,
    parentId: 2,
    type: type,
    text: text,
    key: key,
    semanticsId: semanticsId,
    label: null,
    rect: const QaRect(0, 0, 10, 10),
    viewId: 0,
    visible: true,
    interactive: type != 'Text',
    enabled: true,
    visibleRect: const QaRect(0, 0, 10, 10),
  );

  Future<int> Function(Selector) counts(Map<Selector, int> table) =>
      (s) async => table[s] ?? 0;

  test('ranks ids, then text, then text with childOf, then type and index, without duplicates', () async {
    final hit = ElementHit(
      node: node(text: 'Sign in'),
      selectors: const [
        Selector(text: 'Sign in'),
        Selector(id: 'login'),
        Selector(id: 'login'),
        Selector(type: 'Text', index: 4),
      ],
    );
    final out = await suggestSelectors(
      hit,
      counts({
        const Selector(id: 'login'): 1,
        const Selector(text: 'Sign in'): 2,
        const Selector(
          text: 'Sign in',
          within: Selector(id: 'login'),
        ): 1,
        const Selector(type: 'Text', index: 4): 1,
      }),
    );
    expect(out.map((s) => s.label), [
      'id: login',
      'text: Sign in',
      'text: Sign in, childOf: {id: login}',
      'type: Text, index: 4',
    ]);
    expect(out.map((s) => s.matches), [1, 2, 1, 1]);
    expect(out.map((s) => s.isUnique), [true, false, true, true]);
    expect(bestSuggestion(out)!.label, 'id: login');
  });

  test("the hit's own id is never used as childOf; without text there is no childOf suggestion", () async {
    final hit = ElementHit(
      node: node(type: 'TextField', key: 'password'),
      selectors: const [
        Selector(id: 'password'),
        Selector(id: 'form'),
        Selector(type: 'TextField', index: 1),
      ],
    );
    final out = await suggestSelectors(hit, counts({}));
    expect(out.map((s) => s.label), ['id: password', 'id: form', 'type: TextField, index: 1']);
  });

  test('text with only the own id gets no childOf suggestion', () async {
    final hit = ElementHit(
      node: node(type: 'Tooltip', text: 'Opens a dialog', semanticsId: 'open'),
      selectors: const [
        Selector(id: 'open'),
        Selector(text: 'Opens a dialog'),
      ],
    );
    final out = await suggestSelectors(hit, counts({}));
    expect(out.map((s) => s.label), ['id: open', 'text: Opens a dialog']);
  });

  test('best falls back to the first suggestion and flags it when none is unique', () async {
    final hit = ElementHit(
      node: node(type: 'ListTile', text: 'Item'),
      selectors: const [
        Selector(text: 'Item'),
        Selector(type: 'ListTile', index: 0),
      ],
    );
    final out = await suggestSelectors(
      hit,
      counts({const Selector(text: 'Item'): 3, const Selector(type: 'ListTile', index: 0): 2}),
    );
    final best = bestSuggestion(out)!;
    expect(best.label, 'text: Item');
    expect(best.isUnique, isFalse);
    expect(bestSuggestion(const []), isNull);
  });

  test('selectorLabel writes every field in flow order', () {
    expect(
      selectorLabel(
        const Selector(
          id: 'a',
          text: 'b',
          type: 'c',
          index: 1,
          enabled: false,
          within: Selector(id: 'd'),
        ),
      ),
      'id: a, text: b, type: c, index: 1, enabled: false, childOf: {id: d}',
    );
  });
}
