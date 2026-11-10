import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';
import 'package:qaflow_agent/src/screenshot.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'helpers.dart';

QaResponse decodeResponse(String raw) => QaResponse.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());

void main() {
  allowDevicePointerPropagation();

  testWidgets('capture writes a PNG into the configured directory', (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final previousDir = QaAgent.screenshotDirectory;
    addTearDown(() => QaAgent.screenshotDirectory = previousDir);
    QaAgent.screenshotDirectory = dir.path;
    await pumpApp(tester, const Scaffold(body: Center(child: Text('Shot'))));

    final result = await tester.runAsync(() => Screenshot.capture(waitForFrame: false));
    final file = File(result!['path'] as String);
    expect(file.parent.path, dir.path);
    final bytes = file.readAsBytesSync();
    expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    // The test surface is 800x600 logical pixels at a device pixel ratio of 3.
    expect(result['devicePixelRatio'], 3.0);
    expect(result['width'], 2400);
    expect(result['height'], 1800);
  });

  testWidgets('capture honours an explicit path', (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    await pumpApp(tester, const Scaffold(body: Text('x')));
    final path = '${dir.path}/nested/named.png';
    final result = await tester.runAsync(() => Screenshot.capture(path: path, waitForFrame: false));
    expect(result!['path'], path);
    expect(File(path).existsSync(), isTrue);
  });

  testWidgets('without QaAgent.wrap the method is unsupported', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('x')));
    await expectLater(
      Screenshot.capture(waitForFrame: false),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.unsupported)),
    );
  });

  testWidgets('inline transfer is the default and writes no file', (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final previousDir = QaAgent.screenshotDirectory;
    addTearDown(() => QaAgent.screenshotDirectory = previousDir);
    QaAgent.screenshotDirectory = dir.path;
    await pumpApp(tester, const Scaffold(body: Center(child: Text('Shot'))));

    // QaAgent.handle awaits a frame (endOfFrame) before the real IO
    // (toImage, toByteData) that runAsync exists for. Nothing pumps frames
    // automatically inside runAsync's real zone, so this drives the one
    // frame the handler is waiting on before awaiting the result.
    final future = tester.runAsync(() => QaAgent.handle(QaMethod.screenshot, null));
    await tester.pump();
    final raw = await future;
    final response = decodeResponse(raw!);
    expect(response.ok, isTrue);
    expect(response.result!['format'], 'png');
    final bytes = base64Decode(response.result!['data'] as String);
    expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    // The test surface is 800x600 logical pixels at a device pixel ratio of 3.
    expect(response.result!['devicePixelRatio'], 3.0);
    expect(response.result!['width'], 2400);
    expect(response.result!['height'], 1800);
    expect(dir.listSync(), isEmpty);
  });

  testWidgets('transfer: file keeps writing a file', (tester) async {
    final dir = Directory.systemTemp.createTempSync('qa_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    await pumpApp(tester, const Scaffold(body: Text('x')));
    final path = '${dir.path}/nested/named.png';
    final future = tester.runAsync(
      () => QaAgent.handle(QaMethod.screenshot, jsonEncode({'transfer': 'file', 'path': path})),
    );
    await tester.pump();
    final raw = await future;
    final response = decodeResponse(raw!);
    expect(response.ok, isTrue);
    expect(response.result!['path'], path);
    expect(File(path).existsSync(), isTrue);
  });

  testWidgets('unknown transfer is bad_request', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('x')));
    final raw = await QaAgent.handle(QaMethod.screenshot, jsonEncode({'transfer': 'carrier-pigeon'}));
    final response = decodeResponse(raw);
    expect(response.ok, isFalse);
    expect(response.code, QaErrorCode.badRequest);
  });
}
