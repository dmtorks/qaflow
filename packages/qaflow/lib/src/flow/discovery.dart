import 'dart:io';

import 'package:path/path.dart' as p;

import 'model.dart';

/// Expands files and folders into flow files. A folder contributes the
/// `.yaml`/`.yml` files directly inside it, sorted by name, skipping
/// `config.yaml` and `project.yaml`; subfolders hold shared subflows and are not run directly.
List<String> discoverFlowFiles(List<String> paths) {
  final out = <String>[];
  void add(String path) {
    final normalised = p.normalize(p.absolute(path));
    if (!out.contains(normalised)) out.add(normalised);
  }

  for (final path in paths) {
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.directory:
        final files =
            Directory(path)
                .listSync()
                .whereType<File>()
                .map((f) => f.path)
                .where(_isFlowFile)
                .where((f) => !const {'config.yaml', 'project.yaml'}.contains(p.basename(f)))
                .toList()
              ..sort((a, b) => p.basename(a).compareTo(p.basename(b)));
        files.forEach(add);
      case FileSystemEntityType.file:
        if (!_isFlowFile(path)) throw ArgumentError('not a .yaml or .yml file: $path');
        add(path);
      default:
        throw ArgumentError('no such file or folder: $path');
    }
  }
  return out;
}

bool _isFlowFile(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == '.yaml' || ext == '.yml';
}

/// Keeps flows with at least one [include] tag (all flows when empty), then
/// drops flows with any [exclude] tag.
List<Flow> selectFlows(List<Flow> flows, {Set<String> include = const {}, Set<String> exclude = const {}}) => [
  for (final f in flows)
    if ((include.isEmpty || f.header.tags.any(include.contains)) && !f.header.tags.any(exclude.contains)) f,
];
