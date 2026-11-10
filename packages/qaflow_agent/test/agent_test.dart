import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

Map<String, Object?> decode(String s) => (jsonDecode(s) as Map).cast<String, Object?>();

void main() {
  testWidgets('ping reports version, mode and the views', (tester) async {
    await tester.pumpWidget(QaAgent.wrap(const Placeholder()));
    final response = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.ping, '{}')));
    expect(response.ok, isTrue);
    expect(response.v, protocolVersion);
    expect(response.result!['mode'], 'debug');
    expect(response.result!.containsKey('flutterVersion'), isTrue);
    final views = response.result!['views'] as List;
    expect(views, hasLength(1));
    expect((views.first as Map)['viewId'], 0);
  });

  testWidgets('ping stores the screenshot directory', (tester) async {
    await tester.pumpWidget(QaAgent.wrap(const Placeholder()));
    await QaAgent.handle(QaMethod.ping, jsonEncode({'screenshotDirectory': '/tmp/qa-shots'}));
    expect(QaAgent.screenshotDirectory, '/tmp/qa-shots');
  });

  testWidgets('malformed args produce bad_request', (tester) async {
    final response = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.ping, '[1,2')));
    expect(response.ok, isFalse);
    expect(response.code, QaErrorCode.badRequest);
  });

  testWidgets('resetState is unsupported without a hook and calls the hook when set', (tester) async {
    addTearDown(() => QaAgent.onReset = null);
    QaAgent.onReset = null;
    final none = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.resetState, '{}')));
    expect(none.ok, isFalse);
    expect(none.code, QaErrorCode.unsupported);

    var calls = 0;
    QaAgent.onReset = () async {
      calls++;
    };
    final ok = QaResponse.fromJson(decode(await QaAgent.handle(QaMethod.resetState, '{}')));
    expect(ok.ok, isTrue);
    expect(calls, 1);
  });
}
