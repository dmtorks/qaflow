import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

Future<QaResponse> call(WidgetTester tester, QaMethod m, Map<String, Object?> args) async {
  final raw = await pumpUntil(tester, QaAgent.handle(m, jsonEncode(args)));
  return QaResponse.fromJson((jsonDecode(raw) as Map).cast());
}

void main() {
  allowDevicePointerPropagation();

  testWidgets('enterText appends at the cursor, fires onChanged and runs formatters', (tester) async {
    final changes = <String>[];
    final controller = TextEditingController(text: 'ab');
    await pumpApp(
      tester,
      Scaffold(
        body: TextField(
          key: const ValueKey('f'),
          controller: controller,
          onChanged: changes.add,
          inputFormatters: [TextInputFormatter.withFunction((_, n) => n.copyWith(text: n.text.toUpperCase()))],
        ),
      ),
    );
    controller.selection = const TextSelection.collapsed(offset: 2);
    final r = await call(tester, QaMethod.enterText, {
      'selector': {'id': 'f'},
      'text': 'cd',
    });
    expect(r.ok, isTrue, reason: r.message);
    expect(controller.text, 'ABCD');
    expect(r.result!['value'], 'ABCD');
    expect(changes, ['ABCD']);
  });

  testWidgets('enterText without a selector uses the focused field, or is not_ready', (tester) async {
    final controller = TextEditingController();
    await pumpApp(tester, Scaffold(body: TextField(controller: controller)));
    final none = await call(tester, QaMethod.enterText, {'text': 'x'});
    expect(none.code, QaErrorCode.notReady);
    await call(tester, QaMethod.tap, {
      'selector': {'type': 'TextField'},
    });
    final ok = await call(tester, QaMethod.enterText, {'text': 'hello'});
    expect(ok.ok, isTrue, reason: ok.message);
    expect(controller.text, 'hello');
  });

  testWidgets('eraseText removes characters before the cursor', (tester) async {
    final controller = TextEditingController(text: 'hello');
    await pumpApp(
      tester,
      Scaffold(
        body: TextField(key: const ValueKey('f'), controller: controller),
      ),
    );
    final r = await call(tester, QaMethod.eraseText, {
      'selector': {'id': 'f'},
      'count': 2,
    });
    expect(r.result!['value'], 'hel');
    final all = await call(tester, QaMethod.eraseText, {
      'selector': {'id': 'f'},
      'count': 99,
    });
    expect(all.result!['value'], '');
  });

  testWidgets('setText replaces the value and leaves the cursor at the end', (tester) async {
    final controller = TextEditingController(text: 'old');
    await pumpApp(
      tester,
      Scaffold(
        body: TextField(key: const ValueKey('f'), controller: controller),
      ),
    );
    await call(tester, QaMethod.setText, {
      'selector': {'id': 'f'},
      'text': 'new value',
    });
    expect(controller.text, 'new value');
    expect(controller.selection.baseOffset, 9);
  });

  testWidgets('a selector that is not a text field is not_found', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('plain')));
    final r = await call(tester, QaMethod.setText, {'selector': 'plain', 'text': 'x'});
    expect(r.code, QaErrorCode.notFound);
  });

  testWidgets('the selector is resolved once, before the edit, so a text match that the edit '
      'invalidates still reports the edited node and is not double-applied', (tester) async {
    final controller = TextEditingController(text: 'draft');
    await pumpApp(tester, Scaffold(body: TextField(controller: controller)));
    final r = await call(tester, QaMethod.enterText, {
      'selector': {'text': 'draft'},
      'text': '!',
    });
    expect(r.ok, isTrue, reason: r.message);
    expect(r.result!['value'], 'draft!');
    expect(QaNode.fromJson((r.result!['node'] as Map).cast()).type, 'EditableText');
    expect(controller.text, 'draft!');
  });

  testWidgets('a read-only field via selector is not_ready and left unchanged', (tester) async {
    final controller = TextEditingController(text: 'locked');
    await pumpApp(
      tester,
      Scaffold(
        body: TextField(key: const ValueKey('f'), controller: controller, readOnly: true),
      ),
    );
    final r = await call(tester, QaMethod.enterText, {
      'selector': {'id': 'f'},
      'text': 'x',
    });
    expect(r.code, QaErrorCode.notReady);
    expect(controller.text, 'locked');
  });

  testWidgets('a disabled field via selector is rejected and left unchanged', (tester) async {
    // TextField(enabled: false) composes to EditableText(readOnly: true), and
    // the TextField's own render box (matched by the selector) sits outside
    // the inner IgnorePointer, so actionPoint's hit test still succeeds and
    // resolution reaches the readOnly check below: this is not_ready, the
    // same code a readOnly field reports, not an actionPoint obscured error.
    final controller = TextEditingController(text: 'locked');
    await pumpApp(
      tester,
      Scaffold(
        body: TextField(key: const ValueKey('f'), controller: controller, enabled: false),
      ),
    );
    final r = await call(tester, QaMethod.enterText, {
      'selector': {'id': 'f'},
      'text': 'x',
    });
    expect(r.code, QaErrorCode.notReady, reason: r.message);
    expect(controller.text, 'locked');
  });
}
