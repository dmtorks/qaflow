import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:yaml/yaml.dart';

import '../device/device.dart';
import '../screenshot/baseline_store.dart';
import 'model.dart';
import 'variables.dart';

class FlowParseException implements Exception {
  FlowParseException(this.file, this.line, this.column, this.message);
  final String file;
  final int line;
  final int column;
  final String message;
  @override
  String toString() => '$file:$line:$column: $message';
}

typedef _Entry = (YamlNode key, YamlNode value);

/// Parses flow files. One parser caches every file it parsed successfully,
/// so a run shares one instance and parses each subflow once.
class FlowParser {
  final Map<String, Flow> _cache = {};
  final List<String> _stack = [];

  static const Set<String> headerKeys = {'appId', 'name', 'tags', 'env', 'onFlowStart', 'onFlowComplete'};

  static const Set<String> commandNames = {
    'launchApp',
    'stopApp',
    'killApp',
    'clearState',
    'tapOn',
    'doubleTapOn',
    'longPressOn',
    'hover',
    'inputText',
    'eraseText',
    'setText',
    'pressKey',
    'back',
    'hideKeyboard',
    'setOrientation',
    'openLink',
    'assertVisible',
    'assertNotVisible',
    'extendedWaitUntil',
    'waitForAnimationToEnd',
    'scroll',
    'scrollUntilVisible',
    'swipe',
    'takeScreenshot',
    'assertScreenshot',
    'runFlow',
    'repeat',
  };

  /// Maestro commands QAFlow does not run.
  static const Set<String> unsupportedCommands = {
    'addMedia',
    'assertDarkMode',
    'assertLightMode',
    'assertNoDefectsWithAI',
    'assertTrue',
    'assertWithAI',
    'clearKeychain',
    'copyTextFrom',
    'evalScript',
    'extractTextWithAI',
    'inputRandomEmail',
    'inputRandomNumber',
    'inputRandomPersonName',
    'inputRandomText',
    'pasteText',
    'retry',
    'runScript',
    'setAirplaneMode',
    'setClipboard',
    'setDarkMode',
    'setLocation',
    'setPermissions',
    'startRecording',
    'stopRecording',
    'toggleAirplaneMode',
    'toggleDarkMode',
    'travel',
  };

  static const Set<String> selectorKeys = {'text', 'id', 'index', 'enabled', 'childOf', 'type'};

  static const Set<String> unsupportedSelectorKeys = {
    'checked',
    'focused',
    'selected',
    'above',
    'below',
    'leftOf',
    'rightOf',
    'containsChild',
    'containsDescendants',
    'traits',
    'width',
    'height',
    'tolerance',
  };

  static const Set<String> unsupportedTapOptions = {'repeat', 'delay', 'retryTapIfNoChange', 'waitToSettleTimeoutMs'};

  Flow parseFile(String path) {
    final file = p.normalize(p.absolute(path));
    final cached = _cache[file];
    if (cached != null) return cached;
    if (_stack.contains(file)) {
      throw FlowParseException(file, 1, 1, 'runFlow cycle: ${[..._stack, file].map(p.basename).join(' -> ')}');
    }
    final String text;
    try {
      text = File(file).readAsStringSync();
    } on FileSystemException catch (e) {
      throw FlowParseException(file, 1, 1, 'cannot read flow file: ${e.osError?.message ?? e.message}');
    }
    _stack.add(file);
    try {
      final flow = _FileParser(this, file).parse(text);
      _cache[file] = flow;
      return flow;
    } finally {
      _stack.removeLast();
    }
  }

  /// Parses [text] as if it were the file at [path]: errors name [path],
  /// relative `runFlow` files resolve against its folder, and a `runFlow`
  /// back to [path] is a cycle. The result is not cached, so an editor can
  /// call this on every change; subflows it reaches are cached as usual.
  Flow parseText(String text, String path) {
    final file = p.normalize(p.absolute(path));
    if (_stack.contains(file)) {
      throw FlowParseException(file, 1, 1, 'runFlow cycle: ${[..._stack, file].map(p.basename).join(' -> ')}');
    }
    _stack.add(file);
    try {
      return _FileParser(this, file).parse(text);
    } finally {
      _stack.removeLast();
    }
  }
}

class _FileParser {
  _FileParser(this.owner, this.file);
  final FlowParser owner;
  final String file;

  Never fail(YamlNode node, String message) {
    final start = node.span.start;
    throw FlowParseException(file, start.line + 1, start.column + 1, message);
  }

  SourceRef ref(YamlNode node) => SourceRef(file, node.span.start.line + 1, node.span.start.column + 1);

  Flow parse(String text) {
    final List<YamlDocument> docs;
    try {
      docs = loadYamlDocuments(text, sourceUrl: Uri.file(file));
    } on YamlException catch (e) {
      final start = e.span?.start;
      throw FlowParseException(file, (start?.line ?? 0) + 1, (start?.column ?? 0) + 1, e.message);
    }
    if (docs.isEmpty) throw FlowParseException(file, 1, 1, 'the flow file is empty');
    if (docs.length > 2) fail(docs[2].contents, 'a flow file has a header, ---, and one command list');
    final headerNode = docs.length == 2 ? docs[0].contents : null;
    final body = docs.last.contents;
    if (body is YamlMap) {
      fail(body, 'expected a command list; put the header before a --- line');
    }
    if (body is YamlScalar && body.value == null) {
      fail(body, 'the flow has no commands');
    }
    return Flow(
      file: file,
      header: headerNode == null ? const FlowHeader() : header(headerNode),
      commands: commands(body, 'the flow body'),
    );
  }

  // ---- building blocks ----

  Map<String, _Entry> entries(YamlMap map) {
    final out = <String, _Entry>{};
    for (final e in map.nodes.entries) {
      final keyNode = e.key as YamlNode;
      final key = keyNode.value;
      // YAML reads a bare `true:` key (Maestro's JavaScript condition) as a
      // boolean, so scalar keys are compared by their text.
      if (key is! String && key is! bool && key is! num) fail(keyNode, 'keys must be plain names');
      out[key.toString()] = (keyNode, e.value);
    }
    return out;
  }

  String string(YamlNode node, String what) {
    final v = node.value;
    if (v is! String && v is! num && v is! bool) fail(node, '$what must be a string');
    final s = v.toString();
    final bad = VariableScope.invalidReferences(s);
    if (bad.isNotEmpty) fail(node, 'JavaScript expressions are not supported: \${${bad.first}}');
    return s;
  }

  int integer(YamlNode node, String what, {int? min, int? max}) {
    final v = node.value;
    if (v is! int) fail(node, '$what must be a whole number');
    if (min != null && v < min) fail(node, '$what must be at least $min');
    if (max != null && v > max) fail(node, '$what must be at most $max');
    return v;
  }

  bool boolean(YamlNode node, String what) {
    final v = node.value;
    if (v is! bool) fail(node, '$what must be true or false');
    return v;
  }

  ({String? label, bool optional, Map<String, _Entry> rest}) withOptions(YamlMap map) {
    final all = entries(map);
    final label = all.remove('label');
    final optional = all.remove('optional');
    return (
      label: label == null ? null : string(label.$2, 'label'),
      optional: optional == null ? false : boolean(optional.$2, 'optional'),
      rest: all,
    );
  }

  void allowOnly(Map<String, _Entry> rest, Set<String> allowed, String command) {
    for (final e in rest.entries) {
      if (!allowed.contains(e.key)) fail(e.value.$1, '$command does not accept "${e.key}"');
    }
  }

  Direction direction(YamlNode node) {
    final v = string(node, 'direction').toLowerCase();
    return switch (v) {
      'up' => Direction.up,
      'down' => Direction.down,
      'left' => Direction.left,
      'right' => Direction.right,
      _ => fail(node, 'direction must be UP, DOWN, LEFT or RIGHT'),
    };
  }

  PointSpec point(YamlNode node, String what) =>
      PointSpec.tryParse(string(node, what)) ?? fail(node, '$what must be "x, y" or "x%, y%"');

  // ---- header ----

  FlowHeader header(YamlNode node) {
    if (node is YamlScalar && node.value == null) return const FlowHeader();
    if (node is! YamlMap) fail(node, 'the header before --- must be a map');
    final e = entries(node);
    for (final k in e.keys) {
      if (!FlowParser.headerKeys.contains(k)) fail(e[k]!.$1, 'unknown header field $k');
    }
    return FlowHeader(
      name: e['name'] == null ? null : string(e['name']!.$2, 'name'),
      tags: e['tags'] == null ? const [] : tags(e['tags']!.$2),
      env: e['env'] == null ? const {} : env(e['env']!.$2),
      onFlowStart: e['onFlowStart'] == null ? const [] : commands(e['onFlowStart']!.$2, 'onFlowStart'),
      onFlowComplete: e['onFlowComplete'] == null ? const [] : commands(e['onFlowComplete']!.$2, 'onFlowComplete'),
    );
  }

  List<String> tags(YamlNode node) {
    if (node is YamlScalar) return [string(node, 'tags')];
    if (node is! YamlList) fail(node, 'tags must be a list of strings');
    return [for (final t in node.nodes) string(t, 'a tag')];
  }

  Map<String, String> env(YamlNode node) {
    if (node is! YamlMap) fail(node, 'env must be a map of names to values');
    final out = <String, String>{};
    for (final e in entries(node).entries) {
      try {
        VariableScope.parseAssignments(['${e.key}=']);
      } on FormatException {
        fail(e.value.$1, 'invalid variable name ${e.key}');
      }
      final value = e.value.$2;
      if (value.value == null) fail(value, 'env value for ${e.key} is missing');
      out[e.key] = string(value, 'env value');
    }
    return out;
  }

  // ---- commands ----

  List<Command> commands(YamlNode node, String what) {
    if (node is! YamlList) fail(node, '$what must be a list of commands');
    return [for (final n in node.nodes) command(n)];
  }

  Command command(YamlNode node) {
    final String name;
    final YamlNode nameNode;
    YamlNode? value;
    if (node is YamlScalar && node.value is String) {
      name = node.value as String;
      nameNode = node;
    } else if (node is YamlMap) {
      if (node.nodes.length != 1) fail(node, 'a command is a single key, e.g. "- tapOn: Login"');
      final e = node.nodes.entries.single;
      nameNode = e.key as YamlNode;
      name = nameNode.value.toString();
      value = e.value;
      if (value is YamlScalar && value.value == null) value = null;
    } else {
      fail(node, 'expected a command');
    }
    if (FlowParser.unsupportedCommands.contains(name)) fail(nameNode, '$name is not supported by QAFlow');
    if (!FlowParser.commandNames.contains(name)) fail(nameNode, 'unknown command $name${suggest(name)}');
    final src = ref(nameNode);
    return switch (name) {
      'launchApp' => launchApp(src, value),
      'stopApp' || 'killApp' => lifecycle(src, value, name),
      'clearState' => lifecycle(src, value, name),
      'tapOn' => tap(src, value, TapKind.tap, nameNode),
      'doubleTapOn' => tap(src, value, TapKind.doubleTap, nameNode),
      'longPressOn' => tap(src, value, TapKind.longPress, nameNode),
      'hover' => hover(src, value, nameNode),
      'inputText' => inputText(src, value, nameNode),
      'eraseText' => eraseText(src, value),
      'setText' => setText(src, value, nameNode),
      'pressKey' => pressKey(src, value, nameNode),
      'back' || 'hideKeyboard' => bare(src, value, name),
      'setOrientation' => setOrientation(src, value, nameNode),
      'openLink' => openLink(src, value, nameNode),
      'assertVisible' => assertion(src, value, nameNode, visible: true),
      'assertNotVisible' => assertion(src, value, nameNode, visible: false),
      'extendedWaitUntil' => extendedWait(src, value, nameNode),
      'waitForAnimationToEnd' => waitForAnimation(src, value),
      'scroll' => scroll(src, value),
      'scrollUntilVisible' => scrollUntilVisible(src, value, nameNode),
      'swipe' => swipe(src, value, nameNode),
      'takeScreenshot' => takeScreenshot(src, value, nameNode),
      'assertScreenshot' => assertScreenshot(src, value, nameNode),
      'runFlow' => runFlow(src, value, nameNode),
      'repeat' => repeat(src, value, nameNode),
      _ => fail(nameNode, 'unknown command $name'),
    };
  }

  YamlMap mapValue(YamlNode? value, YamlNode at, String command) {
    if (value is YamlMap) return value;
    fail(value ?? at, '$command needs a map of options');
  }

  Command launchApp(SourceRef src, YamlNode? value) {
    if (value == null || value is YamlScalar) return LaunchApp(source: src);
    final o = withOptions(mapValue(value, value, 'launchApp'));
    allowOnly(o.rest, {'clearState', 'stopApp', 'appId'}, 'launchApp');
    return LaunchApp(
      source: src,
      label: o.label,
      optional: o.optional,
      clearState: o.rest['clearState'] == null ? false : boolean(o.rest['clearState']!.$2, 'clearState'),
      stopApp: o.rest['stopApp'] == null ? true : boolean(o.rest['stopApp']!.$2, 'stopApp'),
    );
  }

  Command lifecycle(SourceRef src, YamlNode? value, String name) {
    String? label;
    var optional = false;
    if (value is YamlMap) {
      final o = withOptions(value);
      allowOnly(o.rest, {'appId'}, name);
      label = o.label;
      optional = o.optional;
    }
    // A scalar value is Maestro's appId, which this runner ignores.
    return name == 'clearState'
        ? ClearState(source: src, label: label, optional: optional)
        : StopApp(source: src, label: label, optional: optional, commandName: name);
  }

  Command bare(SourceRef src, YamlNode? value, String name) {
    String? label;
    var optional = false;
    if (value is YamlMap) {
      final o = withOptions(value);
      allowOnly(o.rest, const {}, name);
      label = o.label;
      optional = o.optional;
    } else if (value != null) {
      fail(value, '$name takes no value');
    }
    return name == 'back'
        ? Back(source: src, label: label, optional: optional)
        : HideKeyboard(source: src, label: label, optional: optional);
  }

  Command setOrientation(SourceRef src, YamlNode? value, YamlNode at) {
    YamlNode node;
    String? label;
    var optional = false;
    if (value is YamlMap) {
      final o = withOptions(value);
      allowOnly(o.rest, {'orientation'}, 'setOrientation');
      node = (o.rest['orientation'] ?? fail(value, 'setOrientation needs orientation')).$2;
      label = o.label;
      optional = o.optional;
    } else {
      node = value ?? fail(at, 'setOrientation needs PORTRAIT, LANDSCAPE_LEFT or LANDSCAPE_RIGHT');
    }
    final orientation = switch (string(node, 'orientation').trim().toUpperCase()) {
      'PORTRAIT' => ScreenOrientation.portrait,
      'LANDSCAPE' || 'LANDSCAPE_LEFT' => ScreenOrientation.landscapeLeft,
      'LANDSCAPE_RIGHT' => ScreenOrientation.landscapeRight,
      _ => fail(node, 'orientation must be PORTRAIT, LANDSCAPE_LEFT or LANDSCAPE_RIGHT'),
    };
    return SetOrientation(source: src, label: label, optional: optional, orientation: orientation);
  }

  Command openLink(SourceRef src, YamlNode? value, YamlNode at) {
    YamlNode node;
    String? label;
    var optional = false;
    if (value is YamlMap) {
      final o = withOptions(value);
      // autoVerify and browser are Maestro's; accepted and ignored.
      allowOnly(o.rest, {'link', 'autoVerify', 'browser'}, 'openLink');
      node = (o.rest['link'] ?? fail(value, 'openLink needs link')).$2;
      label = o.label;
      optional = o.optional;
    } else {
      node = value ?? fail(at, 'openLink needs a link');
    }
    final link = string(node, 'link');
    if (!VariableScope.hasReferences(link) && Uri.tryParse(link)?.hasScheme != true) {
      fail(node, 'openLink needs an absolute URL with a scheme, e.g. demo://app/item/1');
    }
    return OpenLink(source: src, label: label, optional: optional, link: link);
  }

  Command tap(SourceRef src, YamlNode? value, TapKind kind, YamlNode at) {
    final name = switch (kind) {
      TapKind.tap => 'tapOn',
      TapKind.doubleTap => 'doubleTapOn',
      TapKind.longPress => 'longPressOn',
    };
    if (value == null) fail(at, '$name needs a selector or a point');
    if (value is YamlScalar) {
      return Tap(
        source: src,
        kind: kind,
        selector: FlowSelector(text: string(value, 'text')),
      );
    }
    if (value is! YamlMap) fail(value, '$name needs a selector or a point');
    final o = withOptions(value);
    for (final e in o.rest.entries) {
      if (FlowParser.unsupportedTapOptions.contains(e.key)) fail(e.value.$1, '$name option ${e.key} is not supported');
    }
    final pointEntry = o.rest.remove('point');
    if (pointEntry != null) {
      if (o.rest.isNotEmpty) fail(at, 'point cannot be combined with selector fields');
      return Tap(source: src, label: o.label, optional: o.optional, kind: kind, point: point(pointEntry.$2, 'point'));
    }
    return Tap(source: src, label: o.label, optional: o.optional, kind: kind, selector: selectorFrom(o.rest, value));
  }

  ({String? label, bool optional, FlowSelector selector}) selectorCommand(YamlNode? value, YamlNode at, String name) {
    if (value == null) fail(at, '$name needs a selector');
    if (value is YamlScalar) return (label: null, optional: false, selector: FlowSelector(text: string(value, 'text')));
    if (value is! YamlMap) fail(value, '$name needs a selector');
    final o = withOptions(value);
    return (label: o.label, optional: o.optional, selector: selectorFrom(o.rest, value));
  }

  Command hover(SourceRef src, YamlNode? value, YamlNode at) {
    final s = selectorCommand(value, at, 'hover');
    return Hover(source: src, label: s.label, optional: s.optional, selector: s.selector);
  }

  Command assertion(SourceRef src, YamlNode? value, YamlNode at, {required bool visible}) {
    final s = selectorCommand(value, at, visible ? 'assertVisible' : 'assertNotVisible');
    return visible
        ? AssertVisible(source: src, label: s.label, optional: s.optional, selector: s.selector)
        : AssertNotVisible(source: src, label: s.label, optional: s.optional, selector: s.selector);
  }

  Command inputText(SourceRef src, YamlNode? value, YamlNode at) {
    if (value == null) fail(at, 'inputText needs text');
    if (value is YamlScalar) return InputText(source: src, text: string(value, 'text'));
    final o = withOptions(mapValue(value, at, 'inputText'));
    allowOnly(o.rest, {'text'}, 'inputText');
    final text = o.rest['text'] ?? fail(value, 'inputText needs text');
    return InputText(source: src, label: o.label, optional: o.optional, text: string(text.$2, 'text'));
  }

  Command eraseText(SourceRef src, YamlNode? value) {
    if (value == null) return EraseText(source: src);
    if (value is YamlScalar) return EraseText(source: src, count: integer(value, 'eraseText', min: 1));
    final o = withOptions(mapValue(value, value, 'eraseText'));
    allowOnly(o.rest, {'charactersToErase'}, 'eraseText');
    final count = o.rest['charactersToErase'];
    return EraseText(
      source: src,
      label: o.label,
      optional: o.optional,
      count: count == null ? 50 : integer(count.$2, 'charactersToErase', min: 1),
    );
  }

  Command setText(SourceRef src, YamlNode? value, YamlNode at) {
    final o = withOptions(mapValue(value, at, 'setText'));
    allowOnly(o.rest, {'element', 'text'}, 'setText');
    final element = o.rest['element'] ?? fail(at, 'setText needs element');
    final text = o.rest['text'] ?? fail(at, 'setText needs text');
    return SetText(
      source: src,
      label: o.label,
      optional: o.optional,
      selector: selector(element.$2, 'element'),
      text: string(text.$2, 'text'),
    );
  }

  Command pressKey(SourceRef src, YamlNode? value, YamlNode at) {
    YamlNode keyNode;
    String? label;
    var optional = false;
    if (value is YamlMap) {
      final o = withOptions(value);
      allowOnly(o.rest, {'key'}, 'pressKey');
      keyNode = (o.rest['key'] ?? fail(value, 'pressKey needs key')).$2;
      label = o.label;
      optional = o.optional;
    } else {
      keyNode = value ?? fail(at, 'pressKey needs a key');
    }
    final key = string(keyNode, 'key');
    if (key.trim().toLowerCase() == 'back') {
      return Back(source: src, label: label, optional: optional, written: 'pressKey back');
    }
    if (!VariableScope.hasReferences(key)) {
      try {
        KeyChord.parse(key);
      } on FormatException catch (e) {
        fail(keyNode, e.message);
      }
    }
    return PressKey(source: src, label: label, optional: optional, key: key);
  }

  Command extendedWait(SourceRef src, YamlNode? value, YamlNode at) {
    final o = withOptions(mapValue(value, at, 'extendedWaitUntil'));
    allowOnly(o.rest, {'visible', 'notVisible', 'timeout'}, 'extendedWaitUntil');
    final visible = o.rest['visible'];
    final notVisible = o.rest['notVisible'];
    if ((visible == null) == (notVisible == null)) {
      fail(at, 'extendedWaitUntil needs exactly one of visible or notVisible');
    }
    final timeout = o.rest['timeout'] ?? fail(at, 'extendedWaitUntil needs timeout (ms)');
    return ExtendedWaitUntil(
      source: src,
      label: o.label,
      optional: o.optional,
      visible: visible == null ? null : selector(visible.$2, 'visible'),
      notVisible: notVisible == null ? null : selector(notVisible.$2, 'notVisible'),
      timeoutMs: integer(timeout.$2, 'timeout', min: 0),
    );
  }

  Command waitForAnimation(SourceRef src, YamlNode? value) {
    if (value == null) return WaitForAnimationToEnd(source: src);
    final o = withOptions(mapValue(value, value, 'waitForAnimationToEnd'));
    allowOnly(o.rest, {'timeout'}, 'waitForAnimationToEnd');
    final timeout = o.rest['timeout'];
    return WaitForAnimationToEnd(
      source: src,
      label: o.label,
      optional: o.optional,
      timeoutMs: timeout == null ? 5000 : integer(timeout.$2, 'timeout', min: 0),
    );
  }

  Command scroll(SourceRef src, YamlNode? value) {
    if (value == null) return Scroll(source: src);
    final o = withOptions(mapValue(value, value, 'scroll'));
    allowOnly(o.rest, const {}, 'scroll');
    return Scroll(source: src, label: o.label, optional: o.optional);
  }

  Command scrollUntilVisible(SourceRef src, YamlNode? value, YamlNode at) {
    final o = withOptions(mapValue(value, at, 'scrollUntilVisible'));
    allowOnly(o.rest, {
      'element',
      'direction',
      'timeout',
      'speed',
      'visibilityPercentage',
      'centerElement',
      'scrollable',
    }, 'scrollUntilVisible');
    final r = o.rest;
    final element = r['element'] ?? fail(at, 'scrollUntilVisible needs element');
    if (r['speed'] != null) integer(r['speed']!.$2, 'speed', min: 0, max: 100);
    return ScrollUntilVisible(
      source: src,
      label: o.label,
      optional: o.optional,
      element: selector(element.$2, 'element'),
      direction: r['direction'] == null ? Direction.down : direction(r['direction']!.$2),
      timeoutMs: r['timeout'] == null ? 20000 : integer(r['timeout']!.$2, 'timeout', min: 0),
      visibilityPercentage: r['visibilityPercentage'] == null
          ? 100
          : integer(r['visibilityPercentage']!.$2, 'visibilityPercentage', min: 0, max: 100),
      centerElement: r['centerElement'] == null ? false : boolean(r['centerElement']!.$2, 'centerElement'),
      scrollable: r['scrollable'] == null ? null : selector(r['scrollable']!.$2, 'scrollable'),
    );
  }

  Command swipe(SourceRef src, YamlNode? value, YamlNode at) {
    final o = withOptions(mapValue(value, at, 'swipe'));
    allowOnly(o.rest, {'direction', 'start', 'end', 'from', 'duration'}, 'swipe');
    final r = o.rest;
    final hasDirection = r['direction'] != null;
    final hasPoints = r['start'] != null || r['end'] != null;
    if (hasDirection == hasPoints) fail(at, 'swipe needs either direction or start and end');
    if (hasPoints && (r['start'] == null || r['end'] == null)) fail(at, 'swipe needs both start and end');
    if (hasPoints && r['from'] != null) fail(r['from']!.$1, 'from works only with direction');
    return Swipe(
      source: src,
      label: o.label,
      optional: o.optional,
      direction: hasDirection ? direction(r['direction']!.$2) : null,
      start: hasPoints ? point(r['start']!.$2, 'start') : null,
      end: hasPoints ? point(r['end']!.$2, 'end') : null,
      from: r['from'] == null ? null : selector(r['from']!.$2, 'from'),
      durationMs: r['duration'] == null ? 400 : integer(r['duration']!.$2, 'duration', min: 0),
    );
  }

  Command takeScreenshot(SourceRef src, YamlNode? value, YamlNode at) {
    if (value == null) fail(at, 'takeScreenshot needs a name');
    if (value is YamlScalar) return TakeScreenshot(source: src, fileName: string(value, 'name'));
    final o = withOptions(mapValue(value, at, 'takeScreenshot'));
    allowOnly(o.rest, {'path'}, 'takeScreenshot');
    final path = o.rest['path'] ?? fail(value, 'takeScreenshot needs path');
    return TakeScreenshot(source: src, label: o.label, optional: o.optional, fileName: string(path.$2, 'path'));
  }

  Command assertScreenshot(SourceRef src, YamlNode? value, YamlNode at) {
    YamlNode nameNode;
    String? label;
    var optional = false;
    var threshold = 0.1;
    var ignore = const <FlowSelector>[];
    if (value is YamlMap) {
      final o = withOptions(value);
      allowOnly(o.rest, {'name', 'threshold', 'ignore'}, 'assertScreenshot');
      nameNode = (o.rest['name'] ?? fail(value, 'assertScreenshot needs name')).$2;
      label = o.label;
      optional = o.optional;
      if (o.rest['threshold'] case (_, final node)) {
        final v = node.value;
        if (v is! num || v.isNaN || v < 0 || v > 100) fail(node, 'threshold must be between 0 and 100');
        threshold = v.toDouble();
      }
      if (o.rest['ignore'] case (_, final node)) {
        if (node is! YamlList) fail(node, 'ignore must be a list of selectors');
        ignore = [for (final n in node.nodes) selector(n, 'ignore')];
      }
    } else {
      nameNode = value ?? fail(at, 'assertScreenshot needs a name');
    }
    final name = string(nameNode, 'name');
    if (!VariableScope.hasReferences(name)) {
      final problem = BaselineStore.nameProblem(name);
      if (problem != null) fail(nameNode, problem);
    }
    return AssertScreenshot(
      source: src,
      label: label,
      optional: optional,
      screenshotName: name,
      threshold: threshold,
      ignore: ignore,
    );
  }

  Command runFlow(SourceRef src, YamlNode? value, YamlNode at) {
    if (value == null) fail(at, 'runFlow needs a file or commands');
    if (value is YamlScalar) return fileRunFlow(src, value, label: null, optional: false, env: const {}, when: null);
    final o = withOptions(mapValue(value, at, 'runFlow'));
    allowOnly(o.rest, {'file', 'commands', 'env', 'when'}, 'runFlow');
    final r = o.rest;
    if ((r['file'] == null) == (r['commands'] == null)) fail(at, 'runFlow needs exactly one of file or commands');
    final envMap = r['env'] == null ? const <String, String>{} : env(r['env']!.$2);
    final when = r['when'] == null ? null : condition(r['when']!.$2, 'when');
    if (r['file'] != null) {
      return fileRunFlow(src, r['file']!.$2, label: o.label, optional: o.optional, env: envMap, when: when);
    }
    return RunFlow(
      source: src,
      label: o.label,
      optional: o.optional,
      commands: commands(r['commands']!.$2, 'runFlow commands'),
      env: envMap,
      when: when,
    );
  }

  Command fileRunFlow(
    SourceRef src,
    YamlNode fileNode, {
    required String? label,
    required bool optional,
    required Map<String, String> env,
    required Condition? when,
  }) {
    final raw = string(fileNode, 'file');
    Flow? subflow;
    if (!VariableScope.hasReferences(raw)) {
      final resolved = p.normalize(p.join(p.dirname(file), raw));
      if (owner._stack.contains(resolved)) {
        fail(fileNode, 'runFlow cycle: ${[...owner._stack, resolved].map(p.basename).join(' -> ')}');
      }
      if (!File(resolved).existsSync()) fail(fileNode, 'runFlow file not found: $raw');
      subflow = owner.parseFile(resolved);
    }
    return RunFlow(source: src, label: label, optional: optional, file: raw, subflow: subflow, env: env, when: when);
  }

  Command repeat(SourceRef src, YamlNode? value, YamlNode at) {
    final o = withOptions(mapValue(value, at, 'repeat'));
    allowOnly(o.rest, {'times', 'while', 'commands'}, 'repeat');
    final r = o.rest;
    if (r['times'] == null && r['while'] == null) fail(at, 'repeat needs times or while');
    final list = r['commands'] ?? fail(at, 'repeat needs commands');
    return Repeat(
      source: src,
      label: o.label,
      optional: o.optional,
      times: r['times'] == null ? null : integer(r['times']!.$2, 'times', min: 1),
      whileCondition: r['while'] == null ? null : condition(r['while']!.$2, 'while'),
      commands: commands(list.$2, 'repeat commands'),
    );
  }

  Condition condition(YamlNode node, String what) {
    if (node is! YamlMap) fail(node, '$what must be a map of conditions');
    final e = entries(node);
    allowOnly(e, {'visible', 'notVisible', 'platform', 'true'}, what);
    if (e.isEmpty) fail(node, '$what needs at least one condition');
    String? platform;
    if (e['platform'] != null) {
      final raw = string(e['platform']!.$2, 'platform');
      platform = switch (raw.toLowerCase()) {
        'ios' => 'iOS',
        'android' => 'Android',
        'macos' => 'macOS',
        'windows' => 'Windows',
        'linux' => 'Linux',
        _ => fail(e['platform']!.$2, 'platform must be iOS, Android, macOS, Windows or Linux'),
      };
    }
    return Condition(
      visible: e['visible'] == null ? null : selector(e['visible']!.$2, 'visible'),
      notVisible: e['notVisible'] == null ? null : selector(e['notVisible']!.$2, 'notVisible'),
      platform: platform,
      isTrue: e['true'] == null ? null : string(e['true']!.$2, 'true'),
    );
  }

  // ---- selectors ----

  FlowSelector selector(YamlNode node, String what) {
    if (node is YamlScalar) return FlowSelector(text: string(node, what));
    if (node is! YamlMap) fail(node, '$what must be text or a map of selector fields');
    final o = entries(node);
    return selectorFrom(o, node);
  }

  FlowSelector selectorFrom(Map<String, _Entry> fields, YamlNode at) {
    for (final e in fields.entries) {
      if (FlowParser.unsupportedSelectorKeys.contains(e.key)) {
        fail(e.value.$1, 'selector field ${e.key} is not supported');
      }
      if (!FlowParser.selectorKeys.contains(e.key)) fail(e.value.$1, 'unknown selector field ${e.key}');
    }
    final s = FlowSelector(
      text: fields['text'] == null ? null : string(fields['text']!.$2, 'text'),
      id: fields['id'] == null ? null : string(fields['id']!.$2, 'id'),
      index: fields['index'] == null ? null : integer(fields['index']!.$2, 'index', min: 0),
      enabled: fields['enabled'] == null ? null : boolean(fields['enabled']!.$2, 'enabled'),
      type: fields['type'] == null ? null : string(fields['type']!.$2, 'type'),
      childOf: fields['childOf'] == null ? null : selector(fields['childOf']!.$2, 'childOf'),
    );
    if (s.text == null && s.id == null && s.type == null && s.childOf == null) {
      fail(fields.values.isEmpty ? at : fields.values.first.$1, 'a selector needs text, id, type or childOf');
    }
    return s;
  }

  String suggest(String name) {
    String? best;
    var bestDistance = 4;
    for (final candidate in FlowParser.commandNames) {
      final d = _distance(name.toLowerCase(), candidate.toLowerCase());
      if (d < bestDistance) {
        best = candidate;
        bestDistance = d;
      }
    }
    return best == null ? '' : ' (did you mean $best?)';
  }

  static int _distance(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}
