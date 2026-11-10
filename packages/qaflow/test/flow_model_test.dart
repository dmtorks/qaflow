import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  test('PointSpec parses percentages and pixels and resolves against a box', () {
    final pct = PointSpec.tryParse('90%, 50%')!;
    expect(pct.resolve(left: 0, top: 0, width: 800, height: 600), (x: 720.0, y: 300.0));
    final px = PointSpec.tryParse(' 12 ,34.5 ')!;
    expect(px.resolve(left: 100, top: 100, width: 10, height: 10), (x: 112.0, y: 134.5));
    final mixed = PointSpec.tryParse('50%, 10')!;
    expect(mixed.resolve(left: 10, top: 20, width: 200, height: 100), (x: 110.0, y: 30.0));
    expect(PointSpec.tryParse('50%'), isNull);
    expect(PointSpec.tryParse('a, b'), isNull);
    expect(pct.toString(), '90%, 50%');
  });

  test('commands describe themselves and prefer a label', () {
    const src = SourceRef('f.yaml', 3, 3);
    const tap = Tap(
      source: src,
      kind: TapKind.doubleTap,
      selector: FlowSelector(text: 'OK'),
    );
    expect(tap.name, 'doubleTapOn');
    expect(tap.title, 'doubleTapOn text: "OK"');
    const labelled = Tap(
      source: src,
      kind: TapKind.tap,
      selector: FlowSelector(id: 'go'),
      label: 'Press go',
    );
    expect(labelled.title, 'Press go');
    expect(const StopApp(source: src, commandName: 'killApp').name, 'killApp');
  });

  test('a flow is named by its header or its file', () {
    const header = FlowHeader(name: 'Login');
    expect(const Flow(file: '/x/login_flow.yaml', header: header, commands: []).name, 'Login');
    expect(const Flow(file: '/x/login_flow.yaml', header: FlowHeader(), commands: []).name, 'login_flow');
  });
}
