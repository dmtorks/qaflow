import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  test('parses event lines', () {
    final m = DaemonProtocol.parseLine(
      '[{"event":"app.debugPort","params":{"appId":"a1","port":5,"wsUri":"ws://127.0.0.1:5/ws"}}]',
    )!;
    expect(m.event, 'app.debugPort');
    expect(m.params['wsUri'], 'ws://127.0.0.1:5/ws');
    expect(m.id, isNull);
  });

  test('parses responses and tolerates CRLF', () {
    final m = DaemonProtocol.parseLine('[{"id":3,"result":true}]\r')!;
    expect(m.id, 3);
    expect(m.result, isTrue);
  });

  test('ignores lines that are not daemon frames', () {
    expect(DaemonProtocol.parseLine('Launching lib/main_qa.dart on macOS in profile mode...'), isNull);
    expect(DaemonProtocol.parseLine('[{"broken":'), isNull);
    expect(DaemonProtocol.parseLine(''), isNull);
  });

  test('encodes requests as a single-element array with a newline', () {
    expect(
      DaemonProtocol.encodeRequest(1, 'app.stop', {'appId': 'a1'}),
      '[{"id":1,"method":"app.stop","params":{"appId":"a1"}}]\n',
    );
  });
}
