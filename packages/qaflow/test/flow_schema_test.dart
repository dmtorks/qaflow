import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

/// Agreement tests: the schema the editor suggests from must describe exactly
/// what the parser accepts. A key or command added to one and not the other
/// fails here.
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('flow_schema_test');
    File(p.join(dir.path, 'login.yaml')).writeAsStringSync('- back\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('every description is non-empty', () {
    for (final c in FlowSchema.commands) {
      expect(c.description, isNotEmpty, reason: c.name);
      for (final k in c.keys) {
        expect(k.description, isNotEmpty, reason: '${c.name}.${k.name}');
      }
    }
    for (final k in [...FlowSchema.headerKeySpecs, ...FlowSchema.selectorKeySpecs, ...FlowSchema.conditionKeySpecs]) {
      expect(k.description, isNotEmpty, reason: k.name);
    }
  });

  test('key specs match the key lists', () {
    expect({for (final k in FlowSchema.headerKeySpecs) k.name}, FlowParser.headerKeys);
    expect([for (final k in FlowSchema.selectorKeySpecs) k.name], FlowSchema.selectorKeys);
    expect([for (final k in FlowSchema.conditionKeySpecs) k.name], FlowSchema.conditionKeys);
    expect(FlowSchema.headerKey('env')?.kind, ValueKind.env);
    expect(FlowSchema.headerKey('nope'), isNull);
  });

  Flow parse(String yaml) => FlowParser().parseText(yaml, p.join(dir.path, 'f.yaml'));

  void expectParses(String yaml) {
    expect(() => parse(yaml), returnsNormally, reason: yaml);
  }

  const tapFamily = {'tapOn', 'doubleTapOn', 'longPressOn'};

  // Keys the parser accepts on their own but rejects together.
  bool exclusive(String command, String a, String b) {
    bool pair(String x, String y) => (a == x && b == y) || (a == y && b == x);
    if (tapFamily.contains(command)) {
      return (a == 'point' && FlowSchema.selectorKeys.contains(b)) ||
          (b == 'point' && FlowSchema.selectorKeys.contains(a));
    }
    return switch (command) {
      'extendedWaitUntil' => pair('visible', 'notVisible'),
      'swipe' => pair('direction', 'start') || pair('direction', 'end') || pair('from', 'start') || pair('from', 'end'),
      'runFlow' => pair('file', 'commands'),
      _ => false,
    };
  }

  // Keys that are only valid alongside another key.
  const companions = {
    'swipe': {
      'start': ['end'],
      'end': ['start'],
    },
  };

  String example(KeySpec key) => key.example!;

  String mapYaml(String command, Map<String, String> entries) {
    final b = StringBuffer('- $command:');
    if (entries.isEmpty) {
      b.write(' {}');
    }
    for (final e in entries.entries) {
      final value = e.value;
      if (value.contains('\n') || value.startsWith('- ')) {
        b.write('\n    ${e.key}:');
        for (final line in value.split('\n')) {
          b.write('\n      $line');
        }
      } else {
        b.write('\n    ${e.key}: $value');
      }
    }
    return '$b\n';
  }

  Map<String, String> minimalMap(CommandSpec c) {
    final out = <String, String>{};
    if (c.selectorForm) {
      out['text'] = example(c.keys.firstWhere((k) => k.name == 'text'));
    }
    for (final k in c.keys.where((k) => k.required)) {
      out[k.name] = example(k);
    }
    return out;
  }

  Map<String, String> withKey(CommandSpec c, KeySpec key) {
    final map = minimalMap(c);
    final adding = [
      key,
      for (final name in companions[c.name]?[key.name] ?? const <String>[]) c.keys.firstWhere((k) => k.name == name),
    ];
    for (final k in adding) {
      map.removeWhere((name, _) => exclusive(c.name, name, k.name));
    }
    for (final k in adding) {
      map[k.name] = example(k);
    }
    return map;
  }

  String minimalYaml(CommandSpec c) {
    if (c.bare) return '- ${c.name}\n';
    if (c.scalar != null) return '- ${c.name}: ${c.scalarExample}\n';
    return mapYaml(c.name, minimalMap(c));
  }

  test('commands are the parser commands in the same order', () {
    expect(FlowSchema.commands.map((c) => c.name).toList(), FlowParser.commandNames.toList());
    for (final c in FlowSchema.commands) {
      expect(FlowSchema.command(c.name), same(c));
    }
    expect(FlowSchema.command('bogus'), isNull);
  });

  test('header, selector and option key lists match the parser', () {
    expect(FlowSchema.headerKeys, FlowParser.headerKeys.toList());
    expect(FlowSchema.selectorKeys, FlowParser.selectorKeys.toList());
    expect(FlowSchema.optionKeys, ['label', 'optional']);
  });

  test('every command and key is described, every key has an example', () {
    for (final c in FlowSchema.commands) {
      expect(c.description, isNotEmpty, reason: c.name);
      expect(c.scalarExample != null, c.scalar != null, reason: '${c.name} scalarExample iff scalar');
      final names = c.keys.map((k) => k.name).toList();
      expect(names.toSet().length, names.length, reason: '${c.name} has duplicate keys');
      for (final k in c.keys) {
        expect(k.description, isNotEmpty, reason: '${c.name}.${k.name}');
        expect(k.example, isNotNull, reason: '${c.name}.${k.name}');
        expect(FlowSchema.optionKeys, isNot(contains(k.name)), reason: 'option keys are implied');
      }
      if (c.selectorForm) {
        expect(names.where((n) => n != 'point'), FlowSchema.selectorKeys, reason: c.name);
      }
    }
  });

  test('each command\'s minimal example parses', () {
    for (final c in FlowSchema.commands) {
      expectParses(minimalYaml(c));
    }
  });

  test('a command that is not bare needs a value', () {
    for (final c in FlowSchema.commands.where((c) => !c.bare)) {
      expect(() => parse('- ${c.name}\n'), throwsA(isA<FlowParseException>()), reason: c.name);
    }
  });

  test('each key, added to the minimal map with its example, parses', () {
    for (final c in FlowSchema.commands) {
      for (final k in c.keys) {
        expectParses(mapYaml(c.name, withKey(c, k)));
      }
    }
  });

  test('label and optional are accepted on every map form', () {
    for (final c in FlowSchema.commands) {
      expectParses(mapYaml(c.name, {...minimalMap(c), 'label': 'A step', 'optional': 'true'}));
    }
  });

  test('a key not in the schema is a parse error naming it', () {
    for (final c in FlowSchema.commands) {
      expect(
        () => parse(mapYaml(c.name, {...minimalMap(c), 'bogusKey': '1'})),
        throwsA(isA<FlowParseException>().having((e) => e.message, 'message', contains('bogusKey'))),
        reason: c.name,
      );
    }
  });

  test('directions, orientations, platforms and condition keys parse', () {
    expect(FlowSchema.directions, ['UP', 'DOWN', 'LEFT', 'RIGHT']);
    expect(FlowSchema.orientations, ['PORTRAIT', 'LANDSCAPE_LEFT', 'LANDSCAPE_RIGHT']);
    expect(FlowSchema.platforms, ['iOS', 'Android', 'macOS', 'Windows', 'Linux']);
    for (final d in FlowSchema.directions) {
      expectParses('- swipe:\n    direction: $d\n');
    }
    for (final o in FlowSchema.orientations) {
      expectParses('- setOrientation: $o\n');
    }
    for (final pl in FlowSchema.platforms) {
      expectParses('- runFlow:\n    file: login.yaml\n    when:\n      platform: $pl\n');
    }
    const conditionExamples = {'visible': 'Login', 'notVisible': 'Spinner', 'platform': 'Android', 'true': '"yes"'};
    expect(FlowSchema.conditionKeys, conditionExamples.keys.toList());
    for (final key in FlowSchema.conditionKeys) {
      expectParses('- runFlow:\n    file: login.yaml\n    when:\n      $key: ${conditionExamples[key]}\n');
    }
    expect(
      () => parse('- runFlow:\n    file: login.yaml\n    when:\n      bogusKey: 1\n'),
      throwsA(isA<FlowParseException>().having((e) => e.message, 'message', contains('bogusKey'))),
    );
  });

  String whenYaml(String conditions) => '- runFlow:\n    file: login.yaml\n    when:\n$conditions';

  test('every condition key example parses inside a runFlow when', () {
    for (final k in FlowSchema.conditionKeySpecs) {
      expect(k.example, isNotNull, reason: k.name);
      expectParses(whenYaml('      ${k.name}: ${k.example}\n'));
    }
  });

  test('every selector key example parses inside a runFlow when', () {
    final text = FlowSchema.selectorKeySpecs.firstWhere((k) => k.name == 'text');
    for (final k in FlowSchema.selectorKeySpecs) {
      expect(k.example, isNotNull, reason: k.name);
      // index and enabled narrow a match, so they need something to match by.
      final alongside = k == text ? '' : '        text: ${text.example}\n';
      expectParses(whenYaml('      visible:\n$alongside        ${k.name}: ${k.example}\n'));
    }
  });

  // The parser's accepted keys live in allowOnly(...) literals; reading them
  // from its source catches a key added to the parser but not to the schema.
  test('every allowOnly key set in the parser equals the schema keys', () {
    final uri = Isolate.resolvePackageUriSync(Uri.parse('package:qaflow/src/flow/parser.dart'))!;
    final source = File.fromUri(uri).readAsStringSync();
    final callSites = RegExp(r'(?<!void )allowOnly\(').allMatches(source).length;
    final calls = RegExp(
      r"allowOnly\(\w+(?:\.rest)?, (?:const )?\{([^}]*)\}, ('\w+'|\w+)\)",
    ).allMatches(source).toList();
    expect(calls.length, callSites, reason: 'an allowOnly call this test cannot read');
    final methods = RegExp(r'^  (?:Command|Condition) (\w+)\(', multiLine: true).allMatches(source).toList();
    final covered = <String>{};
    for (final call in calls) {
      final keys = RegExp(r"'(\w+)'").allMatches(call[1]!).map((m) => m[1]!).toSet();
      final nameArg = call[2]!;
      final method = methods.lastWhere((m) => m.start < call.start)[1]!;
      if (method == 'condition') {
        expect(FlowSchema.conditionKeys.toSet(), keys, reason: 'condition keys');
        continue;
      }
      final names = nameArg.startsWith("'")
          ? [nameArg.substring(1, nameArg.length - 1)]
          : switch (method) {
              'lifecycle' => ['stopApp', 'killApp', 'clearState'],
              'bare' => ['back', 'hideKeyboard'],
              _ => fail('allowOnly in $method with a computed command name'),
            };
      for (final name in names) {
        final spec = FlowSchema.command(name);
        expect(spec, isNotNull, reason: name);
        expect(spec!.keys.map((k) => k.name).toSet(), keys, reason: name);
        covered.add(name);
      }
    }
    final mapForms = FlowSchema.commands.where((c) => !c.selectorForm).map((c) => c.name).toSet();
    expect(covered, mapForms, reason: 'every non-selector command has an allowOnly key set');
  });
}
