import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

/// A QaTransport whose response is scripted ahead of time and whose calls
/// are recorded, so the driver's wire arguments can be asserted directly
/// without a real agent or VM service.
class ScriptedTransport implements QaTransport {
  ScriptedTransport(this.result);

  final Map<String, Object?> result;
  QaMethod? lastMethod;
  Map<String, Object?>? lastArgs;

  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) async {
    lastMethod = method;
    lastArgs = args;
    return QaResponse.success(result);
  }
}

void main() {
  final pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];

  Map<String, Object?> inlineResult() => {
    'format': 'png',
    'data': base64Encode(pngBytes),
    'width': 10,
    'height': 20,
    'devicePixelRatio': 2.0,
  };

  test('inline transfer decodes and writes exactly the given bytes to an explicit path', () async {
    final dir = Directory.systemTemp.createTempSync('qa_driver_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'nested', 'named.png');
    final transport = ScriptedTransport(inlineResult());
    final driver = QaDriver(transport);

    final result = await driver.screenshot(path: path);

    expect(result, path);
    expect(transport.lastMethod, QaMethod.screenshot);
    expect(transport.lastArgs, {'transfer': 'inline'});
    expect(File(path).readAsBytesSync(), pngBytes);
  });

  test('inline transfer writes a generated name under screenshotDirectory when no path is given', () async {
    final dir = Directory.systemTemp.createTempSync('qa_driver_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final transport = ScriptedTransport(inlineResult());
    final driver = QaDriver(transport, screenshotDirectory: dir.path);

    final result = await driver.screenshot();

    expect(p.dirname(result), dir.path);
    expect(p.basename(result), matches(RegExp(r'^qa_\d+\.png$')));
    expect(File(result).readAsBytesSync(), pngBytes);
  });

  test('inline transfer without a data field raises an internal QaException', () async {
    final transport = ScriptedTransport({'format': 'png', 'width': 1, 'height': 1, 'devicePixelRatio': 1.0});
    final driver = QaDriver(transport);

    await expectLater(
      driver.screenshot(),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.internal)),
    );
  });

  test('file transfer sends transfer: file and returns the agent path unchanged', () async {
    final transport = ScriptedTransport({
      'path': '/agent/side/path.png',
      'width': 1,
      'height': 1,
      'devicePixelRatio': 1.0,
    });
    final driver = QaDriver(transport);

    final result = await driver.screenshot(path: '/wanted/path.png', transfer: ScreenshotTransfer.file);

    expect(result, '/agent/side/path.png');
    expect(transport.lastArgs, {'transfer': 'file', 'path': '/wanted/path.png'});
  });

  test('a driver for an app on a host asks for inline even when file transfer is requested', () async {
    final dir = Directory.systemTemp.createTempSync('qa_driver_shot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'remote.png');
    final transport = ScriptedTransport(inlineResult());
    final driver = QaDriver(transport, inlineScreenshotsOnly: true);

    final result = await driver.screenshot(path: path, transfer: ScreenshotTransfer.file);

    expect(result, path);
    expect(transport.lastArgs, {'transfer': 'inline'});
    expect(File(path).readAsBytesSync(), pngBytes);
  });
}
