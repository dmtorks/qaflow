import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

void main() {
  late TempFlows files;
  setUp(() => files = TempFlows());
  tearDown(() => files.dispose());

  test('a folder contributes its own yaml files, sorted, without subfolders or config.yaml', () {
    files.write('flows/b.yaml', '- scroll\n');
    files.write('flows/a.yml', '- scroll\n');
    files.write('flows/config.yaml', 'x: 1\n');
    files.write('flows/notes.txt', 'ignore me');
    files.write('flows/sub/c.yaml', '- scroll\n');
    final found = discoverFlowFiles([p.join(files.dir, 'flows')]);
    expect(found.map(p.basename), ['a.yml', 'b.yaml']);
    expect(found.every(p.isAbsolute), isTrue);
  });

  test('a folder skips project.yaml', () {
    files.write('flows/a.yaml', '- launchApp\n');
    files.write('flows/project.yaml', 'app:\n  source: .\n');
    expect(discoverFlowFiles([p.join(files.dir, 'flows')]).map(p.basename), ['a.yaml']);
  });

  test('files are kept once in the order given', () {
    final a = files.write('a.yaml', '- scroll\n');
    final b = files.write('b.yaml', '- scroll\n');
    expect(discoverFlowFiles([b, a, b]), [b, a]);
  });

  test('missing paths and non-yaml files are argument errors', () {
    expect(() => discoverFlowFiles([p.join(files.dir, 'nope')]), throwsArgumentError);
    expect(() => discoverFlowFiles([files.write('x.txt', '')]), throwsArgumentError);
  });

  test('selectFlows applies include then exclude tags', () {
    final parser = FlowParser();
    final smoke = parser.parseFile(files.write('s.yaml', 'tags: [smoke]\n---\n- scroll\n'));
    final slow = parser.parseFile(files.write('l.yaml', 'tags: [smoke, slow]\n---\n- scroll\n'));
    final none = parser.parseFile(files.write('n.yaml', '- scroll\n'));
    final all = [smoke, slow, none];
    expect(selectFlows(all), all);
    expect(selectFlows(all, include: {'smoke'}), [smoke, slow]);
    expect(selectFlows(all, exclude: {'slow'}), [smoke, none]);
    expect(selectFlows(all, include: {'smoke'}, exclude: {'slow'}), [smoke]);
  });

  test('validateFlows prints path:line:column: message and counts problems', () {
    files.write('flows/good.yaml', '- scroll\n');
    files.write('flows/bad.yaml', '- scroll\n- travel\n');
    final out = StringBuffer();
    final problems = validateFlows([p.join(files.dir, 'flows')], out, relativeTo: files.dir);
    expect(problems, 1);
    expect(out.toString().trim(), 'flows/bad.yaml:2:3: travel is not supported by QAFlow');

    final clean = StringBuffer();
    expect(validateFlows([p.join(files.dir, 'flows', 'good.yaml')], clean), 0);
    expect(clean.toString().trim(), '1 flow file(s) OK');
  });
}
