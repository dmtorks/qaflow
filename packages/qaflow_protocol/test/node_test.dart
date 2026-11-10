import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('QaRect exposes center and intersection', () {
    const r = QaRect(10, 20, 100, 50);
    expect(r.centerX, 60);
    expect(r.centerY, 45);
    expect(r.intersects(const QaRect(100, 60, 10, 10)), isTrue);
    expect(r.intersects(const QaRect(200, 60, 10, 10)), isFalse);
  });

  test('QaNode round-trips through JSON', () {
    const n = QaNode(
      nodeId: 3,
      parentId: 1,
      type: 'Text',
      text: 'OK',
      key: 'ok',
      semanticsId: null,
      label: null,
      rect: QaRect(0, 0, 10, 10),
      viewId: 0,
      visible: true,
      interactive: false,
      enabled: true,
    );
    final back = QaNode.fromJson(n.toJson());
    expect(back.toJson(), equals(n.toJson()));
    expect(back.rect, equals(const QaRect(0, 0, 10, 10)));
  });

  test('visibleRect round-trips and defaults to null', () {
    const n = QaNode(
      nodeId: 1,
      parentId: null,
      type: 'Text',
      text: null,
      key: null,
      semanticsId: null,
      label: null,
      rect: QaRect(0, -20, 10, 40),
      viewId: 0,
      visible: true,
      interactive: false,
      enabled: true,
      visibleRect: QaRect(0, 0, 10, 20),
    );
    final back = QaNode.fromJson(n.toJson());
    expect(back.visibleRect, const QaRect(0, 0, 10, 20));
    expect(QaNode.fromJson({...n.toJson(), 'visibleRect': null}).visibleRect, isNull);
    final withoutKey = Map<String, Object?>.of(n.toJson())..remove('visibleRect');
    expect(QaNode.fromJson(withoutKey).visibleRect, isNull);
  });
}
