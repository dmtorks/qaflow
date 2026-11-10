import 'dart:io';

import 'package:path/path.dart' as p;

import 'discovery.dart';
import 'parser.dart';

/// Parses every flow under [paths] and writes `path:line:column: message`
/// for each problem (paths relative to [relativeTo], default the current
/// directory). Returns the number of problems.
int validateFlows(List<String> paths, StringSink out, {String? relativeTo}) {
  final files = discoverFlowFiles(paths);
  final parser = FlowParser();
  final base = relativeTo ?? Directory.current.path;
  final problems = <String>{};
  for (final file in files) {
    try {
      parser.parseFile(file);
    } on FlowParseException catch (e) {
      problems.add('${p.relative(e.file, from: base)}:${e.line}:${e.column}: ${e.message}');
    }
  }
  problems.forEach(out.writeln);
  if (problems.isEmpty) out.writeln('${files.length} flow file(s) OK');
  return problems.length;
}
