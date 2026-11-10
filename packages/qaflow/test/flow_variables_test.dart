import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

void main() {
  test('substitutes names from the innermost scope first', () {
    final header = VariableScope({'USER': 'header', 'ONLY_HEADER': 'h'});
    final cli = header.child({'USER': 'cli'});
    final runFlow = cli.child({'USER': 'runflow'});
    expect(runFlow.substitute('hi \${USER}'), 'hi runflow');
    expect(cli.substitute('\${USER}/\${ONLY_HEADER}'), 'cli/h');
  });

  test('leaves text without references unchanged', () {
    expect(VariableScope().substitute(r'price $5 and {braces}'), r'price $5 and {braces}');
  });

  test('an undefined name throws UndefinedVariableException', () {
    expect(
      () => VariableScope().substitute('\${MISSING}'),
      throwsA(isA<UndefinedVariableException>().having((e) => e.name, 'name', 'MISSING')),
    );
  });

  test('invalidReferences finds expressions that are not plain names', () {
    expect(VariableScope.invalidReferences('\${A} \${a + b} \${output.x}'), ['a + b', 'output.x']);
    expect(VariableScope.hasReferences('\${A}'), isTrue);
    expect(VariableScope.hasReferences('none'), isFalse);
  });

  test('parseAssignments reads KEY=VALUE and rejects anything else', () {
    expect(VariableScope.parseAssignments(['A=1', 'B=x=y', 'C=']), {'A': '1', 'B': 'x=y', 'C': ''});
    expect(() => VariableScope.parseAssignments(['novalue']), throwsFormatException);
    expect(() => VariableScope.parseAssignments(['1BAD=x']), throwsFormatException);
  });
}
