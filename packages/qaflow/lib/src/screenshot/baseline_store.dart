import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Screenshot baselines under `<app root>/.qa/baselines/<device key>/<flow slug>/<name>.png`.
class BaselineStore {
  BaselineStore(this.appRoot);

  final String appRoot;

  static final Random _random = Random();

  static final RegExp _name = RegExp(r'^[A-Za-z0-9._-]+$');

  /// Why [name] cannot name a baseline file, or null.
  static String? nameProblem(String name) {
    if (!_name.hasMatch(name) || name == '.' || name == '..') {
      return 'screenshot name "$name" must use only letters, digits, ".", "-" and "_"';
    }
    return null;
  }

  String pathFor({required String deviceKey, required String flowSlug, required String name}) =>
      p.join(appRoot, '.qa', 'baselines', deviceKey, flowSlug, '$name.png');

  Uint8List? read(String path) {
    final f = File(path);
    return f.existsSync() ? f.readAsBytesSync() : null;
  }

  /// A temporary file renamed over [path], so a reader never sees half a PNG.
  void write(String path, List<int> bytes) {
    Directory(p.dirname(path)).createSync(recursive: true);
    // pid alone is not unique: two runs in one QAFlow Studio process can write
    // the same baseline at once.
    final tmp = File('$path.tmp-$pid-${_random.nextInt(1 << 32).toRadixString(16)}');
    try {
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(path);
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }
}
