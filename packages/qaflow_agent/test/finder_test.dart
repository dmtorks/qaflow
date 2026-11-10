import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/src/finder.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

void main() {
  allowDevicePointerPropagation();

  Widget fixture() => Scaffold(
    appBar: AppBar(title: const Text('Title')),
    body: Column(
      children: [
        Semantics(
          identifier: 'greeting',
          label: 'Greeting label',
          child: const Text('Hello', key: ValueKey('hello')),
        ),
        ElevatedButton(key: const ValueKey('go'), onPressed: () {}, child: const Text('Go')),
        const ElevatedButton(onPressed: null, child: Text('Disabled')),
        TextField(
          key: const ValueKey('field'),
          controller: TextEditingController(text: 'typed'),
        ),
        const Offstage(offstage: true, child: Text('Hidden')),
        Card(child: Column(children: const [Text('Inner'), Text('Inner')])),
        const Text('Inner'),
      ],
    ),
  );

  testWidgets('collect reports text, key, semantics, interactivity and rects', (tester) async {
    await pumpApp(tester, fixture());
    final all = QaFinder.collect();
    final hello = all.singleWhere((c) => c.node.key == 'hello');
    expect(hello.node.type, 'Text');
    expect(hello.node.text, 'Hello');
    expect(hello.node.visible, isTrue);
    expect(hello.node.rect!.width, greaterThan(0));
    expect(hello.node.viewId, 0);

    final sem = all.singleWhere((c) => c.node.semanticsId == 'greeting');
    expect(sem.node.label, 'Greeting label');

    final go = all.singleWhere((c) => c.node.key == 'go');
    expect(go.node.interactive, isTrue);
    expect(go.node.enabled, isTrue);

    final disabled = all.singleWhere((c) => c.node.type == 'ElevatedButton' && c.node.key == null);
    expect(disabled.node.enabled, isFalse);

    final editable = all.singleWhere((c) => c.node.type == 'EditableText');
    expect(editable.node.text, 'typed');
  });

  testWidgets('an obscured field never reports its text, so passwords stay out of dumps', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Column(
          children: [
            TextField(
              key: const ValueKey('password'),
              obscureText: true,
              controller: TextEditingController(text: 'hunter2'),
            ),
            TextField(
              key: const ValueKey('email'),
              controller: TextEditingController(text: 'a@b.c'),
            ),
          ],
        ),
      ),
    );
    final editables = QaFinder.collect().where((c) => c.node.type == 'EditableText').toList();
    expect(editables.map((c) => c.node.text), [null, 'a@b.c']);
    expect(QaFinder.find(const Selector(text: 'hunter2')), isEmpty);
    expect(QaFinder.find(const Selector(id: 'password')), hasLength(1), reason: 'still found by its id');
  });

  testWidgets('offstage subtrees are not collected', (tester) async {
    await pumpApp(tester, fixture());
    expect(QaFinder.find(const Selector(text: 'Hidden')), isEmpty);
  });

  testWidgets('text, regex, id, type and within selectors', (tester) async {
    await pumpApp(tester, fixture());
    expect(QaFinder.find(const Selector(text: 'Go')), hasLength(1));
    expect(QaFinder.find(const Selector(textRegex: 'G.')), hasLength(1));
    expect(QaFinder.find(const Selector(textRegex: 'G')), isEmpty, reason: 'regex is a full match');
    expect(QaFinder.find(const Selector(id: 'greeting')), hasLength(1), reason: 'id matches semantics identifier');
    expect(QaFinder.find(const Selector(id: 'go')), hasLength(1), reason: 'id matches ValueKey');
    expect(QaFinder.find(const Selector(type: 'ElevatedButton')), hasLength(2));
    expect(
      QaFinder.find(
        const Selector(
          text: 'Inner',
          within: Selector(type: 'Card'),
        ),
      ),
      hasLength(2),
    );
    expect(
      QaFinder.find(
        const Selector(
          text: 'Inner',
          within: Selector(type: 'Card'),
          index: 1,
        ),
      ),
      hasLength(1),
    );
  });

  testWidgets('resolveOne reports not_found and ambiguous with details', (tester) async {
    await pumpApp(tester, fixture());
    expect(
      () => QaFinder.resolveOne(const Selector(text: 'Nope')),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notFound)),
    );
    expect(
      () => QaFinder.resolveOne(const Selector(text: 'Inner')),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.ambiguous)
            .having((e) => e.details['count'], 'count', 3),
      ),
    );
    expect(QaFinder.resolveOne(const Selector(text: 'Inner', index: 2)).node.text, 'Inner');
  });

  testWidgets('nested matches collapse to the innermost', (tester) async {
    await pumpApp(tester, fixture());
    // Semantics(identifier: greeting) wraps Text(key: hello); an id selector
    // on a Semantics wrapper whose child carries the same key must not be ambiguous.
    await pumpApp(
      tester,
      Semantics(
        identifier: 'same',
        child: const Text('x', key: ValueKey('same')),
      ),
    );
    final hit = QaFinder.resolveOne(const Selector(id: 'same'));
    expect(hit.node.type, 'Text');
  });

  testWidgets('empty selector is a bad request', (tester) async {
    await pumpApp(tester, fixture());
    expect(
      () => QaFinder.find(const Selector()),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.badRequest)),
    );
  });

  testWidgets('tooltip message is a text source', (tester) async {
    await pumpApp(tester, const Tooltip(message: 'Tip', child: Text('x')));
    final hits = QaFinder.find(const Selector(text: 'Tip'));
    expect(hits, hasLength(1));
    expect(hits.single.node.type, 'Tooltip');
  });

  testWidgets('text inside SelectionArea resolves to the Text node, not RichText', (tester) async {
    // Text builds MouseRegion -> _SelectableTextContainer -> _RichText ->
    // RichText under a SelectionRegistrar; the RichText descendant must not
    // also be treated as a text source, or a plain text selector collapses
    // to the innermost (RichText) match instead of the Text node.
    await pumpApp(tester, const SelectionArea(child: Text('Hello')));
    final hit = QaFinder.resolveOne(const Selector(type: 'Text', text: 'Hello'));
    expect(hit.node.type, 'Text');
    final plain = QaFinder.resolveOne(const Selector(text: 'Hello'));
    expect(plain.node.type, 'Text');
  });

  testWidgets('text with semanticsLabel resolves to the Text node, not RichText', (tester) async {
    // semanticsLabel wraps the built RichText in Semantics(child:
    // ExcludeSemantics(child: RichText)); the RichText descendant must not
    // also be treated as a text source, or a plain text selector collapses
    // to the innermost (RichText) match instead of the Text node.
    await pumpApp(tester, const Text('Hello', semanticsLabel: 'Hello label'));
    final hit = QaFinder.resolveOne(const Selector(type: 'Text', text: 'Hello'));
    expect(hit.node.type, 'Text');
    final plain = QaFinder.resolveOne(const Selector(text: 'Hello'));
    expect(plain.node.type, 'Text');
  });

  testWidgets('enabled narrows matches to enabled or disabled widgets', (tester) async {
    await pumpApp(tester, fixture());
    expect(QaFinder.find(const Selector(type: 'ElevatedButton', enabled: true)).single.node.key, 'go');
    expect(QaFinder.find(const Selector(type: 'ElevatedButton', enabled: false)).single.node.key, isNull);
  });

  testWidgets('nodes report the clipped visible rect', (tester) async {
    await pumpApp(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 100,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SizedBox(height: 90),
                Text('Edge', key: ValueKey('edge')),
                SizedBox(height: 300),
                Text('Below', key: ValueKey('below')),
              ],
            ),
          ),
        ),
      ),
    );
    final edge = QaFinder.resolveOne(const Selector(id: 'edge')).node;
    expect(edge.visibleRect, isNotNull);
    expect(edge.visibleRect!.bottom, lessThanOrEqualTo(100.001));
    expect(edge.visibleRect!.height, lessThan(edge.rect!.height));
    expect(QaFinder.resolveOne(const Selector(id: 'below')).node.visibleRect, isNull);
  });

  testWidgets('elements clipped by a scroll view are found but not visible', (tester) async {
    // A Column gives its non-expanded child loose height constraints, so the
    // SizedBox below actually gets to be 100 tall; MaterialApp.home alone
    // would hand it tight constraints matching the full view and the height
    // would be ignored.
    await pumpApp(
      tester,
      Column(
        children: [
          SizedBox(
            height: 100,
            child: SingleChildScrollView(child: Column(children: const [SizedBox(height: 300), Text('Below')])),
          ),
        ],
      ),
    );
    final below = QaFinder.resolveOne(const Selector(text: 'Below'));
    expect(below.node.visible, isFalse);
    expect(below.node.rect, isNotNull);
  });
}
