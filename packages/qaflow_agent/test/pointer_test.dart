import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_agent/src/agent_platform.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

Future<QaResponse> call(WidgetTester tester, QaMethod m, Map<String, Object?> args) async {
  final raw = await pumpUntil(tester, QaAgent.handle(m, jsonEncode(args)));
  return QaResponse.fromJson((jsonDecode(raw) as Map).cast());
}

void main() {
  allowDevicePointerPropagation();
  tearDown(AgentPlatform.reset);

  testWidgets('tap by selector presses a button', (tester) async {
    var taps = 0;
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: ElevatedButton(key: const ValueKey('go'), onPressed: () => taps++, child: const Text('Go')),
        ),
      ),
    );
    final r = await call(tester, QaMethod.tap, {
      'selector': {'id': 'go'},
    });
    expect(r.ok, isTrue, reason: r.message);
    expect(taps, 1);
    expect(QaNode.fromJson((r.result!['node'] as Map).cast()).key, 'go');
  });

  testWidgets('tap by text on a button label presses the button', (tester) async {
    var taps = 0;
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: TextButton(onPressed: () => taps++, child: const Text('OK')),
        ),
      ),
    );
    await call(tester, QaMethod.tap, {'selector': 'OK'});
    expect(taps, 1);
  });

  testWidgets('tap by coordinates and missing target are handled', (tester) async {
    var taps = 0;
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++),
          ),
        ),
      ),
    );
    final r = await call(tester, QaMethod.tap, {'x': 400, 'y': 300});
    expect(r.ok, isTrue);
    expect(taps, 1);
    final bad = await call(tester, QaMethod.tap, {});
    expect(bad.code, QaErrorCode.badRequest);
  });

  testWidgets('hover shows a tooltip and enters a MouseRegion', (tester) async {
    var entered = false;
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: MouseRegion(
            key: const ValueKey('box'),
            onEnter: (_) => entered = true,
            child: const Tooltip(message: 'Tip text', child: SizedBox(width: 80, height: 40)),
          ),
        ),
      ),
    );
    await call(tester, QaMethod.hover, {
      'selector': {'id': 'box'},
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(entered, isTrue);
    expect(find.text('Tip text'), findsOneWidget);
  });

  testWidgets('longPress fires onLongPress', (tester) async {
    var long = 0;
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: GestureDetector(
            key: const ValueKey('lp'),
            behavior: HitTestBehavior.opaque,
            onLongPress: () => long++,
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      ),
    );
    await call(tester, QaMethod.longPress, {
      'selector': {'id': 'lp'},
    });
    expect(long, 1);
  });

  testWidgets('drag moves a draggable', (tester) async {
    Offset? end;
    await pumpApp(
      tester,
      Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 100,
              top: 100,
              child: GestureDetector(
                key: const ValueKey('knob'),
                behavior: HitTestBehavior.opaque,
                onPanEnd: (_) {},
                onPanUpdate: (d) => end = d.globalPosition,
                child: const SizedBox(width: 50, height: 50),
              ),
            ),
          ],
        ),
      ),
    );
    await call(tester, QaMethod.drag, {
      'selector': {'id': 'knob'},
      'dx': 200,
      'dy': 0,
    });
    expect(end!.dx, closeTo(325, 2));
  });

  testWidgets('scroll moves a ListView and reveals later items', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: ListView.builder(
          key: const ValueKey('list'),
          itemCount: 200,
          itemExtent: 48,
          itemBuilder: (_, i) => Text('Row $i'),
        ),
      ),
    );
    expect(find.text('Row 40'), findsNothing);
    final r = await call(tester, QaMethod.scroll, {
      'selector': {'id': 'list'},
      'dy': 1800,
    });
    expect(r.ok, isTrue, reason: r.message);
    expect(find.text('Row 40'), findsOneWidget);
    final back = await call(tester, QaMethod.scroll, {
      'selector': {'id': 'list'},
      'direction': 'up',
      'amount': 5000,
    });
    expect(back.ok, isTrue);
    expect(find.text('Row 0'), findsOneWidget);
  });

  testWidgets('tap with count 2 fires onDoubleTap once', (tester) async {
    var doubles = 0;
    await pumpApp(
      tester,
      Center(
        child: GestureDetector(
          key: const ValueKey('dt'),
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => doubles++,
          child: const SizedBox(width: 80, height: 40),
        ),
      ),
    );
    final r = await call(tester, QaMethod.tap, {
      'selector': {'id': 'dt'},
      'count': 2,
    });
    expect(r.ok, isTrue, reason: r.message);
    await tester.pump(const Duration(milliseconds: 400));
    expect(doubles, 1);
  });

  testWidgets('tap count outside 1 to 3 is a bad request', (tester) async {
    await pumpApp(tester, const Center(child: Text('x')));
    final r = await call(tester, QaMethod.tap, {'selector': 'x', 'count': 0});
    expect(r.code, QaErrorCode.badRequest);
  });

  testWidgets('tap on a covered button is obscured', (tester) async {
    await pumpApp(
      tester,
      Scaffold(
        body: Stack(
          children: [
            Center(
              child: ElevatedButton(key: const ValueKey('under'), onPressed: () {}, child: const Text('U')),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(color: Colors.black38),
              ),
            ),
          ],
        ),
      ),
    );
    final r = await call(tester, QaMethod.tap, {
      'selector': {'id': 'under'},
    });
    expect(r.code, QaErrorCode.obscured);
  });

  testWidgets('taps are touch events on a touch platform, with no hover', (tester) async {
    AgentPlatform.isAndroid = () => true;
    final kinds = <String>[];
    var taps = 0;
    await pumpApp(
      tester,
      Center(
        child: Listener(
          onPointerDown: (e) => kinds.add('down:${e.kind.name}'),
          onPointerHover: (e) => kinds.add('hover:${e.kind.name}'),
          child: ElevatedButton(key: const ValueKey('go'), onPressed: () => taps++, child: const Text('Go')),
        ),
      ),
    );
    final r = await call(tester, QaMethod.tap, {
      'selector': {'id': 'go'},
    });
    expect(r.ok, isTrue, reason: r.message);
    expect(taps, 1);
    expect(kinds, ['down:touch']);
  });

  testWidgets('a touch tap on a button with a tooltip presses it even when frames are slow', (tester) async {
    AgentPlatform.isAndroid = () => true;
    var taps = 0;
    await pumpApp(
      tester,
      Center(
        child: IconButton(
          key: const ValueKey('go'),
          icon: const Icon(Icons.chat_bubble_outline),
          tooltip: 'Go',
          onPressed: () => taps++,
        ),
      ),
    );
    // Each pumped frame takes longer than kLongPressTimeout, as on a loaded emulator.
    final raw = await pumpUntil(
      tester,
      QaAgent.handle(
        QaMethod.tap,
        jsonEncode({
          'selector': {'id': 'go'},
        }),
      ),
      step: kLongPressTimeout + const Duration(milliseconds: 100),
    );
    final r = QaResponse.fromJson((jsonDecode(raw) as Map).cast());
    expect(r.ok, isTrue, reason: r.message);
    expect(taps, 1);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('taps are mouse events on desktop', (tester) async {
    AgentPlatform.isAndroid = () => false;
    AgentPlatform.isIOS = () => false;
    final kinds = <String>[];
    await pumpApp(
      tester,
      Center(
        child: Listener(
          onPointerDown: (e) => kinds.add(e.kind.name),
          child: ElevatedButton(key: const ValueKey('go'), onPressed: () {}, child: const Text('Go')),
        ),
      ),
    );
    await call(tester, QaMethod.tap, {
      'selector': {'id': 'go'},
    });
    expect(kinds, ['mouse']);
  });

  testWidgets('a touch drag scrolls a list', (tester) async {
    AgentPlatform.isIOS = () => true;
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpApp(
      tester,
      ListView.builder(
        controller: controller,
        itemCount: 100,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('Item $i')),
      ),
    );
    final r = await call(tester, QaMethod.drag, {'x': 200.0, 'y': 400.0, 'dx': 0.0, 'dy': -300.0});
    expect(r.ok, isTrue, reason: r.message);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(200));
  });

  testWidgets('hover is unsupported on a touch platform', (tester) async {
    AgentPlatform.isIOS = () => true;
    await pumpApp(tester, const Center(child: Text('Hi')));
    final r = await call(tester, QaMethod.hover, {'selector': 'Hi'});
    expect(r.code, QaErrorCode.unsupported);
    expect(r.message, 'hover needs a mouse; this app runs on a touch platform');
  });
}
