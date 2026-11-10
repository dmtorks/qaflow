import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_agent/src/frames.dart';
import 'package:qaflow_agent/src/settle.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

Map<String, Object?> decode(String s) => (jsonDecode(s) as Map).cast<String, Object?>();

void main() {
  allowDevicePointerPropagation();

  testWidgets('Frames.next completes false once its limit passes while hidden', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('still')));
    await setLifecycle(tester, AppLifecycleState.hidden);
    addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));

    bool? result;
    Frames.next(limit: const Duration(milliseconds: 500)).then((v) => result = v);
    expect(result, isNull);
    await tester.binding.delayed(const Duration(milliseconds: 600));
    expect(result, isFalse);
  });

  testWidgets('Frames.next completes true once a frame runs', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('still')));
    await setLifecycle(tester, AppLifecycleState.hidden);
    addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));

    bool? result;
    Frames.next().then((v) => result = v);
    // A test pump forces a frame through the pipeline directly, regardless
    // of framesEnabled, so this proves next() completes true on a real frame
    // without needing to resume the lifecycle first.
    await tester.pump();
    expect(result, isTrue);
  });

  testWidgets('Settle.waitForIdle throws not_ready within its timeout while hidden', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('still')));
    await setLifecycle(tester, AppLifecycleState.hidden);
    addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));

    Object? error;
    var done = false;
    Settle.waitForIdle(timeout: const Duration(milliseconds: 500)).then(
      (_) {
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(done, isTrue);
    expect(error, isA<QaException>());
    expect((error! as QaException).code, QaErrorCode.notReady);
    expect((error! as QaException).message, contains('the app is not rendering frames'));
  });

  testWidgets('waitForIdle and tap answer not_ready through QaAgent.handle while hidden', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('tap me')));
    await setLifecycle(tester, AppLifecycleState.hidden);
    addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));

    final wait = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.waitForIdle, '{}')));
    expect(wait.ok, isFalse);
    expect(wait.code, QaErrorCode.notReady);
    expect(wait.message, contains('the app is not rendering frames'));

    final tap = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.tap, jsonEncode({'selector': 'tap me'}))));
    expect(tap.ok, isFalse);
    expect(tap.code, QaErrorCode.notReady);
    expect(tap.message, contains('the app is not rendering frames'));
  });

  testWidgets('ping, find and elements still answer while hidden', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('tap me')));
    await setLifecycle(tester, AppLifecycleState.hidden);
    addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));

    final ping = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.ping, '{}')));
    expect(ping.ok, isTrue);

    final find = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.find, jsonEncode({'selector': 'tap me'}))));
    expect(find.ok, isTrue);

    final elements = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.elements, '{}')));
    expect(elements.ok, isTrue);
  });
}
