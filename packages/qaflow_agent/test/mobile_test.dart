import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_agent/src/agent_platform.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

Future<QaResponse> call(WidgetTester tester, QaMethod m, [Map<String, Object?> args = const {}]) async {
  final raw = await pumpUntil(tester, QaAgent.handle(m, jsonEncode(args)));
  return QaResponse.fromJson((jsonDecode(raw) as Map).cast());
}

void main() {
  allowDevicePointerPropagation();
  tearDown(AgentPlatform.reset);

  testWidgets('back pops the top route on Android', (tester) async {
    AgentPlatform.isAndroid = () => true;
    final navigator = GlobalKey<NavigatorState>();
    await pumpApp(tester, const Text('Home'), navigatorKey: navigator);
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('Detail')));
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsOneWidget);

    final r = await call(tester, QaMethod.back);
    await tester.pumpAndSettle();
    expect(r.ok, isTrue, reason: r.message);
    expect(r.result!['popped'], isTrue);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('back is unsupported off Android', (tester) async {
    AgentPlatform.isAndroid = () => false;
    await pumpApp(tester, const Text('Home'));
    final r = await call(tester, QaMethod.back);
    expect(r.ok, isFalse);
    expect(r.code, QaErrorCode.unsupported);
    expect(r.message, 'back is only available on Android');
  });

  testWidgets('hideKeyboard drops focus and reports whether a field had it', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await pumpApp(tester, Scaffold(body: TextField(focusNode: focus)));
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    final r = await call(tester, QaMethod.hideKeyboard);
    expect(r.ok, isTrue, reason: r.message);
    expect(r.result!['hadFocus'], isTrue);
    expect(focus.hasFocus, isFalse);

    final again = await call(tester, QaMethod.hideKeyboard);
    expect(again.result!['hadFocus'], isFalse);
  });

  testWidgets('setOrientation sets the preferred orientation on iOS', (tester) async {
    AgentPlatform.isIOS = () => true;
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpApp(tester, const Text('Home'));

    final r = await call(tester, QaMethod.setOrientation, {'orientation': 'landscapeLeft'});
    expect(r.ok, isTrue, reason: r.message);
    final set = calls.singleWhere((c) => c.method == 'SystemChrome.setPreferredOrientations');
    expect(set.arguments, ['DeviceOrientation.landscapeLeft']);
  });

  testWidgets('setOrientation is unsupported off iOS and rejects unknown values', (tester) async {
    await pumpApp(tester, const Text('Home'));
    AgentPlatform.isIOS = () => false;
    expect((await call(tester, QaMethod.setOrientation, {'orientation': 'portrait'})).code, QaErrorCode.unsupported);
    AgentPlatform.isIOS = () => true;
    final bad = await call(tester, QaMethod.setOrientation, {'orientation': 'sideways'});
    expect(bad.code, QaErrorCode.badRequest);
  });
}
