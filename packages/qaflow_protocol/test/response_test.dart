import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('error codes map to wire strings both ways', () {
    expect(QaErrorCode.notReady.wire, 'not_ready');
    expect(QaErrorCode.fromWire('off_screen'), QaErrorCode.offScreen);
    expect(() => QaErrorCode.fromWire('nope'), throwsArgumentError);
  });

  test('success response carries version and result', () {
    final r = QaResponse.success({'a': 1});
    final json = r.toJson();
    expect(
      json,
      equals({
        'ok': true,
        'v': protocolVersion,
        'result': {'a': 1},
      }),
    );
    expect(QaResponse.fromJson(json).result, equals({'a': 1}));
  });

  test('failure response round-trips code, message and details', () {
    final r = QaResponse.failure(QaErrorCode.obscured, 'covered', {'by': 'Dialog'});
    final back = QaResponse.fromJson(r.toJson());
    expect(back.ok, isFalse);
    expect(back.code, QaErrorCode.obscured);
    expect(back.message, 'covered');
    expect(back.details, equals({'by': 'Dialog'}));
  });

  test('QaMethod maps to extension names', () {
    expect(QaMethod.longPress.extensionName, 'ext.qa.longPress');
    expect(QaMethod.values.length, 19);
    expect(QaMethod.resetState.extensionName, 'ext.qa.resetState');
  });
}
