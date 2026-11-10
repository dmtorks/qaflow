import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('wire names are inline and file', () {
    expect(ScreenshotTransfer.inline.name, 'inline');
    expect(ScreenshotTransfer.file.name, 'file');
  });

  test('fromWire round-trips and rejects unknown values', () {
    expect(ScreenshotTransfer.fromWire('inline'), ScreenshotTransfer.inline);
    expect(ScreenshotTransfer.fromWire('file'), ScreenshotTransfer.file);
    expect(() => ScreenshotTransfer.fromWire('nope'), throwsArgumentError);
  });
}
