import 'dart:convert';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../device/device.dart';
import 'model.dart';

/// A step the recorder can write: a closed set the parser reads back (spec 3.4).
sealed class RecordedStep {
  const RecordedStep();
}

class RecordLaunchApp extends RecordedStep {
  const RecordLaunchApp();
}

class RecordTapOn extends RecordedStep {
  const RecordTapOn(this.selector);
  final Selector selector;
}

class RecordInputText extends RecordedStep {
  const RecordInputText(this.text);
  final String text;
}

class RecordPressKey extends RecordedStep {
  const RecordPressKey(this.key);
  final String key;
}

/// A wheel scroll in [direction]. YAML `scroll` always scrolls down, so any
/// other direction is written as the `swipe` that reveals content on that
/// side (a scroll up is a swipe down).
class RecordScroll extends RecordedStep {
  const RecordScroll(this.direction);
  final Direction direction;
}

class RecordBack extends RecordedStep {
  const RecordBack();
}

class RecordHideKeyboard extends RecordedStep {
  const RecordHideKeyboard();
}

class RecordSetOrientation extends RecordedStep {
  const RecordSetOrientation(this.orientation);
  final ScreenOrientation orientation;
}

class RecordAssertVisible extends RecordedStep {
  const RecordAssertVisible(this.selector);
  final Selector selector;
}

/// Writes one recorded step as a flow list item, in the block form the flow
/// files in this repository use.
class StepWriter {
  const StepWriter();

  String yamlFor(RecordedStep step) => switch (step) {
    RecordLaunchApp() => '- launchApp\n',
    RecordTapOn(:final selector) => '- tapOn:\n${selectorFragment(selector, indent: 4)}',
    RecordInputText(:final text) => '- inputText: ${scalar(text)}\n',
    RecordPressKey(:final key) => '- pressKey: ${scalar(key)}\n',
    RecordScroll(:final direction) => switch (direction) {
      Direction.down => '- scroll\n',
      Direction.up => '- swipe:\n    direction: DOWN\n',
      Direction.left => '- swipe:\n    direction: RIGHT\n',
      Direction.right => '- swipe:\n    direction: LEFT\n',
    },
    RecordBack() => '- back\n',
    RecordHideKeyboard() => '- hideKeyboard\n',
    RecordSetOrientation(:final orientation) =>
      '- setOrientation: ${switch (orientation) {
        ScreenOrientation.portrait => 'PORTRAIT',
        ScreenOrientation.landscapeLeft => 'LANDSCAPE_LEFT',
        ScreenOrientation.landscapeRight => 'LANDSCAPE_RIGHT',
      }}\n',
    RecordAssertVisible(:final selector) => '- assertVisible:\n${selectorFragment(selector, indent: 4)}',
  };

  /// [s] as selector lines in the map form the parser reads (`id`, `text`,
  /// `type`, `index`, `enabled`, `childOf`), each indented by [indent]
  /// spaces and ending in a newline. `key` and `semanticsId` are written as
  /// `id`; `textRegex` has no YAML form and is dropped.
  static String selectorFragment(Selector s, {int indent = 0}) {
    final pad = ' ' * indent;
    final id = s.id ?? s.key ?? s.semanticsId;
    final b = StringBuffer();
    if (id != null) b.write('${pad}id: ${scalar(id)}\n');
    if (s.text != null) b.write('${pad}text: ${scalar(s.text!)}\n');
    if (s.type != null) b.write('${pad}type: ${scalar(s.type!)}\n');
    if (s.index != null) b.write('${pad}index: ${s.index}\n');
    if (s.enabled != null) b.write('${pad}enabled: ${s.enabled}\n');
    if (s.within != null) b.write('${pad}childOf:\n${selectorFragment(s.within!, indent: indent + 2)}');
    return b.toString();
  }

  static final RegExp _plain = RegExp(r'^[A-Za-z][A-Za-z0-9 _./()-]*$');
  static const Set<String> _reserved = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', 'y', 'n'};

  /// [value] as a YAML scalar the parser reads back as the same string:
  /// plain when it is a word-like string YAML cannot take for another type,
  /// otherwise double-quoted (a JSON string is a valid YAML double-quoted
  /// scalar).
  static String scalar(String value) {
    if (_plain.hasMatch(value) && !value.endsWith(' ') && !_reserved.contains(value.toLowerCase())) return value;
    return jsonEncode(value);
  }
}
