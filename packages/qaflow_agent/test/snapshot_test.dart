import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_agent/src/finder.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

Future<QaResponse> call(QaMethod m, Map<String, Object?> args) async =>
    QaResponse.fromJson((jsonDecode(await QaAgent.handle(m, jsonEncode(args))) as Map).cast());

void main() {
  allowDevicePointerPropagation();

  testWidgets('elements returns interesting nodes with parent links', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Card(
          key: const ValueKey('card'),
          child: Column(children: const [Text('A'), Text('B')]),
        ),
      ),
    );
    final r = await call(QaMethod.elements, {});
    final nodes = (r.result!['nodes'] as List).map((n) => QaNode.fromJson((n as Map).cast())).toList();
    final card = nodes.singleWhere((n) => n.key == 'card');
    final a = nodes.singleWhere((n) => n.text == 'A');
    expect(a.parentId, card.nodeId, reason: 'parent is the nearest interesting ancestor');
    expect(nodes.any((n) => n.type == 'Column'), isFalse, reason: 'plain layout widgets are filtered');

    final full = await call(QaMethod.elements, {'all': true});
    expect((full.result!['nodes'] as List).length, greaterThan(nodes.length));
  });

  testWidgets('find returns matching nodes and honours bad selectors', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('Only')));
    final r = await call(QaMethod.find, {
      'selector': {'text': 'Only'},
    });
    expect((r.result!['nodes'] as List), hasLength(1));
    final bad = await call(QaMethod.find, {'selector': {}});
    expect(bad.code, QaErrorCode.badRequest);
    final short = await call(QaMethod.find, {'selector': 'Only'});
    expect((short.result!['nodes'] as List), hasLength(1), reason: 'string selector means text');
  });

  testWidgets('actionPoint detects covered and off-screen targets', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Stack(
          children: [
            Center(
              child: ElevatedButton(key: const ValueKey('under'), onPressed: () {}, child: const Text('Under')),
            ),
            Positioned.fill(
              child: Container(key: const ValueKey('cover'), color: Colors.black54),
            ),
            Positioned(
              left: -500,
              top: 10,
              child: ElevatedButton(key: const ValueKey('offscreen'), onPressed: () {}, child: const Text('Off')),
            ),
          ],
        ),
      ),
    );
    expect(
      () => QaFinder.actionPoint(QaFinder.resolveOne(const Selector(id: 'under'))),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.obscured)),
    );
    expect(
      () => QaFinder.actionPoint(QaFinder.resolveOne(const Selector(id: 'offscreen'))),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.offScreen)),
    );
    final cover = QaFinder.resolveOne(const Selector(id: 'cover'));
    expect(QaFinder.actionPoint(cover), cover.rect!.center);
  });

  testWidgets('disabled interactive targets are not_ready', (tester) async {
    await pumpApp(tester, const Scaffold(body: ElevatedButton(onPressed: null, child: Text('Nope'))));
    expect(
      () => QaFinder.actionPoint(QaFinder.resolveOne(const Selector(type: 'ElevatedButton'))),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.notReady)),
    );
  });

  testWidgets('actionPoint targets the visible part of a partly scrolled item', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        appBar: AppBar(title: const Text('Bar')),
        body: ListView.builder(
          controller: ScrollController(initialScrollOffset: 60),
          itemExtent: 100,
          itemCount: 20,
          itemBuilder: (_, i) => Container(key: ValueKey('row_$i'), color: Colors.amber, child: Text('Row $i')),
        ),
      ),
    );
    final row0 = QaFinder.resolveOne(const Selector(id: 'row_0'));
    final listViewTop = QaFinder.resolveOne(const Selector(type: 'ListView')).rect!.top;
    late Offset point;
    expect(() => point = QaFinder.actionPoint(row0), returnsNormally);
    expect(point.dy, greaterThan(listViewTop));
  });

  testWidgets('elementAt returns the innermost interesting node and selector suggestions', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(key: const ValueKey('go'), onPressed: () {}, child: const Text('Go')),
        ),
      ),
    );
    final go = QaFinder.resolveOne(const Selector(text: 'Go'));
    final r = await call(QaMethod.elementAt, {'x': go.rect!.center.dx, 'y': go.rect!.center.dy});
    final node = QaNode.fromJson((r.result!['node'] as Map).cast());
    expect(node.text, 'Go');
    final selectors = (r.result!['selectors'] as List).map((s) => Selector.fromJson((s as Map).cast())).toList();
    expect(selectors, contains(const Selector(text: 'Go')));
    expect(selectors, contains(const Selector(id: 'go')), reason: 'ancestor keys are suggested too');
  });

  testWidgets("elementAt's type+index suggestion is indexed against find()'s collapsed matches", (tester) async {
    // A colored, opaque GestureDetector so a tap anywhere in its bounds
    // registers as a hit even away from the Text glyphs (per the ruling:
    // "give the GestureDetectors a hit-testable child ... so the tap point
    // hits 'Go'").
    Widget wrapper(Key? key, Widget child) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        width: 80,
        height: 80,
        color: Colors.amber,
        child: Center(child: child),
      ),
    );
    await pumpApp(
      tester,
      Scaffold(
        body: Column(
          children: [
            // An outer GestureDetector wrapping another GestureDetector:
            // QaFinder.find collapses the outer one away because it has a
            // same-type descendant match, so its raw collect() position
            // does not match its position in find()'s result.
            wrapper(null, wrapper(null, const Text('X'))),
            wrapper(const ValueKey('go-wrapper'), const Text('Go')),
          ],
        ),
      ),
    );
    final goWrapper = QaFinder.resolveOne(const Selector(id: 'go-wrapper'));
    final goText = QaFinder.resolveOne(const Selector(text: 'Go'));
    // Tap a corner of the wrapper away from the text glyphs, so the
    // innermost interesting node under the point is the GestureDetector
    // itself rather than its Text child.
    final point = goWrapper.rect!.topLeft + const Offset(4, 4);
    expect(goText.rect!.contains(point), isFalse, reason: 'the tap point must miss the Text child');

    final r = await call(QaMethod.elementAt, {'x': point.dx, 'y': point.dy});
    final node = QaNode.fromJson((r.result!['node'] as Map).cast());
    expect(node.type, 'GestureDetector');

    final selectors = (r.result!['selectors'] as List).map((s) => Selector.fromJson((s as Map).cast())).toList();
    final typeSelector = selectors.singleWhere((s) => s.type == 'GestureDetector');
    expect(
      QaFinder.resolveOne(typeSelector).element,
      same(goWrapper.element),
      reason: 'the suggested index must resolve within find()\'s collapsed matches, not the raw candidate list',
    );
  });

  // The mirror's hover rule (qaflow_studio inspect_state.dart elementAtPoint):
  // the smallest visible interactive rect under the point, the outer node on
  // a tie.
  QaNode? mirrorPick(List<QaNode> nodes, Offset p) {
    QaNode? best;
    var bestArea = double.infinity;
    for (final n in nodes) {
      final r = n.visibleRect;
      if (r == null || !n.visible || !n.interactive) continue;
      if (p.dx < r.x || p.dx >= r.x + r.width || p.dy < r.y || p.dy >= r.y + r.height) continue;
      if (r.width * r.height < bestArea) {
        best = n;
        bestArea = r.width * r.height;
      }
    }
    return best;
  }

  for (final maxLines in [1, 3]) {
    testWidgets('elementAt on a TextField (maxLines $maxLines) reports the EditableText, not its Scrollable', (
      tester,
    ) async {
      await pumpApp(
        tester,
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey('name'),
                maxLines: maxLines,
                controller: TextEditingController(text: 'Ada'),
              ),
            ),
          ),
        ),
      );
      final editable = QaFinder.resolveOne(const Selector(type: 'EditableText'));
      final scrollable = QaFinder.resolveOne(
        const Selector(
          type: 'Scrollable',
          within: Selector(id: 'name'),
        ),
      );
      expect(scrollable.visibleRect, editable.visibleRect, reason: 'the precondition: the two share one rect');
      final point = editable.visibleRect!.center;

      final r = await call(QaMethod.elementAt, {'x': point.dx, 'y': point.dy});
      final node = QaNode.fromJson((r.result!['node'] as Map).cast());
      expect(node.type, 'EditableText');
      expect(node.text, 'Ada');

      final all = await call(QaMethod.elements, {});
      final nodes = (all.result!['nodes'] as List).map((n) => QaNode.fromJson((n as Map).cast())).toList();
      expect(mirrorPick(nodes, point)!.nodeId, node.nodeId, reason: 'the panel names what the mirror outlines');

      final selectors = (r.result!['selectors'] as List).map((s) => Selector.fromJson((s as Map).cast())).toList();
      final scrollableIndex = QaFinder.find(
        const Selector(type: 'Scrollable'),
      ).indexWhere((c) => identical(c.element, scrollable.element));
      expect(selectors, [
        const Selector(id: 'name'),
        Selector(type: 'Scrollable', index: scrollableIndex),
      ], reason: 'the suggestions are unchanged: no text selector built from the field value');
      expect(QaFinder.actionPoint(QaFinder.resolveOne(selectors.last)), editable.visibleRect!.center);
    });
  }

  testWidgets('elementAt keeps a nested control that has its own key or a smaller rect', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Column(
          children: [
            GestureDetector(
              onTap: () {},
              child: GestureDetector(
                key: const ValueKey('inner'),
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(width: 80, height: 80, color: Colors.amber),
              ),
            ),
            GestureDetector(
              key: const ValueKey('outer'),
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: Container(
                width: 120,
                height: 120,
                color: Colors.teal,
                alignment: Alignment.center,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Container(width: 40, height: 40, color: Colors.red),
                ),
              ),
            ),
            GestureDetector(
              key: const ValueKey('same'),
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(width: 60, height: 60, color: Colors.blue),
              ),
            ),
          ],
        ),
      ),
    );
    Future<QaNode> hitAt(Offset p) async {
      final r = await call(QaMethod.elementAt, {'x': p.dx, 'y': p.dy});
      return QaNode.fromJson((r.result!['node'] as Map).cast());
    }

    final inner = QaFinder.resolveOne(const Selector(id: 'inner'));
    expect((await hitAt(inner.rect!.center)).key, 'inner', reason: 'a keyed inner control is never skipped');

    final outer = QaFinder.resolveOne(const Selector(id: 'outer'));
    final small = await hitAt(outer.rect!.center);
    expect(small.type, 'GestureDetector');
    expect(small.key, isNull, reason: 'a smaller inner control is the innermost under the point');

    final same = QaFinder.resolveOne(const Selector(id: 'same'));
    expect((await hitAt(same.rect!.center)).key, 'same', reason: 'a bare inner control with the same rect defers');
  });
}
