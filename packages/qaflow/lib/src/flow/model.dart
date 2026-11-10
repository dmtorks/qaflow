import 'package:path/path.dart' as p;

import '../device/device.dart';

/// Position of a YAML node, 1-based.
class SourceRef {
  const SourceRef(this.file, this.line, this.column);
  final String file;
  final int line;
  final int column;
  @override
  String toString() => '$file:$line:$column';
}

/// A point written as `x, y` (logical pixels) or with `%` on either
/// coordinate (percent of a box's width or height).
class PointSpec {
  const PointSpec(this.x, this.y, {this.xPercent = false, this.yPercent = false});

  static final RegExp _pattern = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*(%?)\s*,\s*(-?\d+(?:\.\d+)?)\s*(%?)\s*$');

  static PointSpec? tryParse(String input) {
    final m = _pattern.firstMatch(input);
    if (m == null) return null;
    return PointSpec(double.parse(m[1]!), double.parse(m[3]!), xPercent: m[2] == '%', yPercent: m[4] == '%');
  }

  final double x;
  final double y;
  final bool xPercent;
  final bool yPercent;

  ({double x, double y}) resolve({
    required double left,
    required double top,
    required double width,
    required double height,
  }) => (x: left + (xPercent ? width * x / 100 : x), y: top + (yPercent ? height * y / 100 : y));

  @override
  String toString() => '${_format(x, xPercent)}, ${_format(y, yPercent)}';

  static String _format(double v, bool percent) => '${v == v.roundToDouble() ? v.toInt() : v}${percent ? '%' : ''}';
}

/// A selector as written in YAML, before variable substitution.
class FlowSelector {
  const FlowSelector({this.text, this.id, this.index, this.enabled, this.childOf, this.type});
  final String? text;
  final String? id;
  final int? index;
  final bool? enabled;
  final FlowSelector? childOf;
  final String? type;

  @override
  String toString() => [
    if (text != null) 'text: "$text"',
    if (id != null) 'id: $id',
    if (type != null) 'type: $type',
    if (enabled != null) 'enabled: $enabled',
    if (index != null) 'index: $index',
    if (childOf != null) 'childOf: ($childOf)',
  ].join(', ');
}

/// `when` / `while`: every given part must hold.
class Condition {
  const Condition({this.visible, this.notVisible, this.platform, this.isTrue});
  final FlowSelector? visible;
  final FlowSelector? notVisible;

  /// `iOS`, `Android`, `macOS`, `Windows` or `Linux`.
  final String? platform;

  /// Must read `true` or `false` after substitution.
  final String? isTrue;
}

enum Direction { up, down, left, right }

enum TapKind { tap, doubleTap, longPress }

sealed class Command {
  const Command({required this.source, this.label, this.optional = false});
  final SourceRef source;
  final String? label;

  /// A failure is recorded as a warning and the flow continues.
  final bool optional;

  /// The YAML command name.
  String get name;

  /// A short description used when there is no [label].
  String describe();

  String get title => label ?? describe();
}

class LaunchApp extends Command {
  const LaunchApp({required super.source, super.label, super.optional, this.clearState = false, this.stopApp = true});
  final bool clearState;
  final bool stopApp;
  @override
  String get name => 'launchApp';
  @override
  String describe() => clearState ? 'launchApp (clearState)' : 'launchApp';
}

class StopApp extends Command {
  const StopApp({required super.source, super.label, super.optional, this.commandName = 'stopApp'});

  /// `stopApp` or `killApp`; both stop the app.
  final String commandName;
  @override
  String get name => commandName;
  @override
  String describe() => commandName;
}

class ClearState extends Command {
  const ClearState({required super.source, super.label, super.optional});
  @override
  String get name => 'clearState';
  @override
  String describe() => 'clearState';
}

class Tap extends Command {
  const Tap({required super.source, super.label, super.optional, required this.kind, this.selector, this.point});
  final TapKind kind;
  final FlowSelector? selector;
  final PointSpec? point;
  @override
  String get name => switch (kind) {
    TapKind.tap => 'tapOn',
    TapKind.doubleTap => 'doubleTapOn',
    TapKind.longPress => 'longPressOn',
  };
  @override
  String describe() => '$name ${selector ?? 'point $point'}';
}

class Hover extends Command {
  const Hover({required super.source, super.label, super.optional, required this.selector});
  final FlowSelector selector;
  @override
  String get name => 'hover';
  @override
  String describe() => 'hover $selector';
}

class InputText extends Command {
  const InputText({required super.source, super.label, super.optional, required this.text});
  final String text;
  @override
  String get name => 'inputText';
  @override
  String describe() => 'inputText "$text"';
}

class EraseText extends Command {
  const EraseText({required super.source, super.label, super.optional, this.count = 50});
  final int count;
  @override
  String get name => 'eraseText';
  @override
  String describe() => 'eraseText $count';
}

class SetText extends Command {
  const SetText({required super.source, super.label, super.optional, required this.selector, required this.text});
  final FlowSelector selector;
  final String text;
  @override
  String get name => 'setText';
  @override
  String describe() => 'setText $selector = "$text"';
}

class PressKey extends Command {
  const PressKey({required super.source, super.label, super.optional, required this.key});
  final String key;
  @override
  String get name => 'pressKey';
  @override
  String describe() => 'pressKey $key';
}

/// Android system back. `pressKey: back` parses to this too.
class Back extends Command {
  const Back({required super.source, super.label, super.optional, this.written = 'back'});

  /// How the step was written, for its title.
  final String written;
  @override
  String get name => 'back';
  @override
  String describe() => written;
}

class HideKeyboard extends Command {
  const HideKeyboard({required super.source, super.label, super.optional});
  @override
  String get name => 'hideKeyboard';
  @override
  String describe() => 'hideKeyboard';
}

class SetOrientation extends Command {
  const SetOrientation({required super.source, super.label, super.optional, required this.orientation});
  final ScreenOrientation orientation;
  @override
  String get name => 'setOrientation';
  @override
  String describe() => 'setOrientation ${orientation.name}';
}

class OpenLink extends Command {
  const OpenLink({required super.source, super.label, super.optional, required this.link});

  /// As written; may contain variables.
  final String link;
  @override
  String get name => 'openLink';
  @override
  String describe() => 'openLink $link';
}

class AssertVisible extends Command {
  const AssertVisible({required super.source, super.label, super.optional, required this.selector});
  final FlowSelector selector;
  @override
  String get name => 'assertVisible';
  @override
  String describe() => 'assertVisible $selector';
}

class AssertNotVisible extends Command {
  const AssertNotVisible({required super.source, super.label, super.optional, required this.selector});
  final FlowSelector selector;
  @override
  String get name => 'assertNotVisible';
  @override
  String describe() => 'assertNotVisible $selector';
}

class ExtendedWaitUntil extends Command {
  const ExtendedWaitUntil({
    required super.source,
    super.label,
    super.optional,
    this.visible,
    this.notVisible,
    required this.timeoutMs,
  });
  final FlowSelector? visible;
  final FlowSelector? notVisible;
  final int timeoutMs;
  @override
  String get name => 'extendedWaitUntil';
  @override
  String describe() => visible != null ? 'wait until visible $visible' : 'wait until not visible $notVisible';
}

class WaitForAnimationToEnd extends Command {
  const WaitForAnimationToEnd({required super.source, super.label, super.optional, this.timeoutMs = 5000});
  final int timeoutMs;
  @override
  String get name => 'waitForAnimationToEnd';
  @override
  String describe() => 'waitForAnimationToEnd';
}

class Scroll extends Command {
  const Scroll({required super.source, super.label, super.optional});
  @override
  String get name => 'scroll';
  @override
  String describe() => 'scroll';
}

class ScrollUntilVisible extends Command {
  const ScrollUntilVisible({
    required super.source,
    super.label,
    super.optional,
    required this.element,
    this.direction = Direction.down,
    this.timeoutMs = 20000,
    this.visibilityPercentage = 100,
    this.centerElement = false,
    this.scrollable,
  });
  final FlowSelector element;
  final Direction direction;
  final int timeoutMs;
  final int visibilityPercentage;
  final bool centerElement;

  /// Flutter extension: which scroll view to scroll.
  final FlowSelector? scrollable;
  @override
  String get name => 'scrollUntilVisible';
  @override
  String describe() => 'scrollUntilVisible $element';
}

class Swipe extends Command {
  const Swipe({
    required super.source,
    super.label,
    super.optional,
    this.direction,
    this.start,
    this.end,
    this.from,
    this.durationMs = 400,
  });
  final Direction? direction;
  final PointSpec? start;
  final PointSpec? end;
  final FlowSelector? from;
  final int durationMs;
  @override
  String get name => 'swipe';
  @override
  String describe() =>
      direction != null ? 'swipe ${direction!.name}${from == null ? '' : ' from $from'}' : 'swipe $start -> $end';
}

class TakeScreenshot extends Command {
  const TakeScreenshot({required super.source, super.label, super.optional, required this.fileName});

  /// File name without `.png`, or a relative path.
  final String fileName;
  @override
  String get name => 'takeScreenshot';
  @override
  String describe() => 'takeScreenshot $fileName';
}

/// Compares the screen with a stored baseline image.
class AssertScreenshot extends Command {
  const AssertScreenshot({
    required super.source,
    super.label,
    super.optional,
    required this.screenshotName,
    this.threshold = 0.1,
    this.ignore = const [],
  });

  /// The baseline's name; may contain variables.
  final String screenshotName;

  /// Largest percentage of differing pixels that still passes.
  final double threshold;

  /// Areas blanked in both images before comparing.
  final List<FlowSelector> ignore;
  @override
  String get name => 'assertScreenshot';
  @override
  String describe() => 'assertScreenshot $screenshotName';
}

class RunFlow extends Command {
  const RunFlow({
    required super.source,
    super.label,
    super.optional,
    this.file,
    this.subflow,
    this.commands,
    this.env = const {},
    this.when,
  });

  /// The path as written (may contain variables).
  final String? file;

  /// Parsed eagerly when [file] has no variables.
  final Flow? subflow;
  final List<Command>? commands;
  final Map<String, String> env;
  final Condition? when;
  @override
  String get name => 'runFlow';
  @override
  String describe() => file != null ? 'runFlow $file' : 'runFlow (inline)';
}

class Repeat extends Command {
  const Repeat({
    required super.source,
    super.label,
    super.optional,
    this.times,
    this.whileCondition,
    required this.commands,
  });
  final int? times;
  final Condition? whileCondition;
  final List<Command> commands;
  @override
  String get name => 'repeat';
  @override
  String describe() => times != null ? 'repeat $times times' : 'repeat while';
}

class FlowHeader {
  const FlowHeader({
    this.name,
    this.tags = const [],
    this.env = const {},
    this.onFlowStart = const [],
    this.onFlowComplete = const [],
  });
  final String? name;
  final List<String> tags;
  final Map<String, String> env;
  final List<Command> onFlowStart;
  final List<Command> onFlowComplete;
}

class Flow {
  const Flow({required this.file, required this.header, required this.commands});

  /// Absolute, normalised path.
  final String file;
  final FlowHeader header;
  final List<Command> commands;

  String get name => header.name ?? p.basenameWithoutExtension(file);
}
