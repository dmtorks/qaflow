import 'dart:convert';

import 'package:flutter/material.dart';
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

  testWidgets('a static screen is idle', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('still')));
    final r = await call(tester, QaMethod.waitForIdle, {});
    expect(r.result!['settled'], 'idle');
  });

  testWidgets('a finite animation becomes idle once it ends', (tester) async {
    await pumpApp(tester, const Scaffold(body: _FiniteFade()));
    final r = await call(tester, QaMethod.waitForIdle, {});
    expect(r.result!['settled'], 'idle');
    expect((r.result!['elapsedMs'] as num), greaterThanOrEqualTo(200));
  });

  testWidgets('an endless spinner settles as stable', (tester) async {
    await pumpApp(tester, const Scaffold(body: Center(child: CircularProgressIndicator())));
    final r = await call(tester, QaMethod.waitForIdle, {});
    expect(r.result!['settled'], 'stable');
    expect((r.result!['frames'] as num), greaterThanOrEqualTo(3));
    expect((r.result!['elapsedMs'] as num), greaterThanOrEqualTo(500));
  });

  testWidgets('tier idle with an endless spinner times out', (tester) async {
    await pumpApp(tester, const Scaffold(body: Center(child: CircularProgressIndicator())));
    final r = await call(tester, QaMethod.waitForIdle, {'tier': 'idle', 'timeoutMs': 500});
    expect(r.result!['settled'], 'timeout');
    expect((r.result!['elapsedMs'] as num), greaterThanOrEqualTo(500));
  });
}

class _FiniteFade extends StatefulWidget {
  const _FiniteFade();
  @override
  State<_FiniteFade> createState() => _FiniteFadeState();
}

class _FiniteFadeState extends State<_FiniteFade> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 300))..forward();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _controller, child: const Text('fading'));
}
