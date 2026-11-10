import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_agent/src/input/keyboard.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

Future<QaResponse> call(WidgetTester tester, QaMethod m, Map<String, Object?> args) async {
  final raw = await pumpUntil(tester, QaAgent.handle(m, jsonEncode(args)));
  return QaResponse.fromJson((jsonDecode(raw) as Map).cast());
}

void main() {
  allowDevicePointerPropagation();

  testWidgets('ctrl+a reaches a Shortcuts binding through the focus tree', (tester) async {
    var fired = 0;
    await pumpApp(
      tester,
      Shortcuts(
        shortcuts: {const SingleActivator(LogicalKeyboardKey.keyA, control: true): const ActivateIntent()},
        child: Actions(
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => fired++)},
          child: const Focus(autofocus: true, child: SizedBox(width: 10, height: 10)),
        ),
      ),
    );
    await tester.pump();
    final r = await call(tester, QaMethod.pressKey, {'key': 'ctrl+a'});
    expect(r.ok, isTrue, reason: r.message);
    expect(fired, 1);
    expect(r.result!['hadFocus'], isTrue);
    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty, reason: 'modifiers are released');
  });

  testWidgets('Focus.onKeyEvent sees the key and character', (tester) async {
    KeyEvent? seen;
    await pumpApp(
      tester,
      Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent) seen = e;
          return KeyEventResult.handled;
        },
        child: const SizedBox(width: 10, height: 10),
      ),
    );
    await tester.pump();
    await call(tester, QaMethod.pressKey, {'key': 'shift+b'});
    expect(seen!.logicalKey, LogicalKeyboardKey.keyB);
    expect(seen!.character, 'B');
  });

  testWidgets('shift+7 sends the US-layout shifted symbol', (tester) async {
    KeyEvent? seen;
    await pumpApp(
      tester,
      Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent) seen = e;
          return KeyEventResult.handled;
        },
        child: const SizedBox(width: 10, height: 10),
      ),
    );
    await tester.pump();
    await call(tester, QaMethod.pressKey, {'key': 'shift+7'});
    expect(seen!.logicalKey, LogicalKeyboardKey.digit7);
    expect(seen!.character, '&');
  });

  testWidgets('enter in a single-line field fires onSubmitted', (tester) async {
    String? submitted;
    await pumpApp(
      tester,
      Scaffold(
        body: TextField(
          autofocus: true,
          controller: TextEditingController(text: 'abc'),
          onSubmitted: (v) => submitted = v,
        ),
      ),
    );
    await tester.pump();
    final r = await call(tester, QaMethod.pressKey, {'key': 'enter'});
    expect(submitted, 'abc');
    expect(r.result!['submitted'], isTrue);
  });

  testWidgets('enter in a multi-line field inserts a newline', (tester) async {
    final controller = TextEditingController(text: 'ab');
    await pumpApp(tester, Scaffold(body: TextField(autofocus: true, controller: controller, maxLines: 3)));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 2);
    await call(tester, QaMethod.pressKey, {'key': 'enter'});
    expect(controller.text, 'ab\n');
  });

  testWidgets('enter that a widget above the field handles is not typed or submitted as well', (tester) async {
    final controller = TextEditingController(text: 'ab');
    var accepted = 0;
    await pumpApp(
      tester,
      Scaffold(
        body: Focus(
          onKeyEvent: (_, e) {
            if (e.logicalKey != LogicalKeyboardKey.enter) return KeyEventResult.ignored;
            if (e is KeyDownEvent) accepted++;
            return KeyEventResult.handled;
          },
          child: TextField(autofocus: true, controller: controller, maxLines: 3),
        ),
      ),
    );
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 2);
    final r = await call(tester, QaMethod.pressKey, {'key': 'enter'});
    expect(accepted, 1);
    expect(controller.text, 'ab');
    expect(r.result!['submitted'], isFalse);
  });

  testWidgets('unknown keys and modifiers are bad requests', (tester) async {
    await pumpApp(tester, const SizedBox());
    expect((await call(tester, QaMethod.pressKey, {'key': 'bogus'})).code, QaErrorCode.badRequest);
    expect((await call(tester, QaMethod.pressKey, {'key': 'hyper+a'})).code, QaErrorCode.badRequest);
    expect((await call(tester, QaMethod.pressKey, {})).code, QaErrorCode.badRequest);
  });

  testWidgets('an unrecognized modifier after a valid one leaves no keys pressed', (tester) async {
    // Bypasses KeyChord.parse (which only ever admits known modifier names)
    // to exercise KeyboardSynth.press directly against a modifier name that
    // canonicalizes to something absent from its own lookup table: exactly
    // the drift-between-packages case that would otherwise dispatch a down
    // event for 'shift' and then throw before its matching up is sent.
    await pumpApp(tester, const SizedBox());
    await expectLater(
      KeyboardSynth.press(const KeyChord(['shift', 'nonexistent'], 'a')),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.badRequest)),
    );
    expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
  });

  test('lookup covers letters, digits, named keys and modifiers', () {
    expect(KeyboardSynth.lookup('a').$1, LogicalKeyboardKey.keyA);
    expect(KeyboardSynth.lookup('7').$2, PhysicalKeyboardKey.digit7);
    expect(KeyboardSynth.lookup('arrowdown').$1, LogicalKeyboardKey.arrowDown);
    expect(KeyboardSynth.lookup('f12').$1, LogicalKeyboardKey.f12);
    expect(KeyboardSynth.lookup('meta').$1, LogicalKeyboardKey.metaLeft);
  });

  test('the agent resolves every name in KeyChord.namedKeys', () {
    for (final name in KeyChord.namedKeys) {
      expect(() => KeyboardSynth.lookup(name), returnsNormally, reason: name);
    }
  });
}
