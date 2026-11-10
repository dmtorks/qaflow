/// A parsed `mod+shift+a` string. Modifier and key names are lower case.
class KeyChord {
  /// A chord of [modifiers] held while [key] is pressed. Use [KeyChord.parse]
  /// to read one from text.
  const KeyChord(this.modifiers, this.key);

  /// The modifier names [KeyChord.parse] accepts. `mod` is Command on macOS
  /// and Control elsewhere; `cmd` and `command` are Meta, `control` is Ctrl
  /// and `option` is Alt.
  static const Set<String> knownModifiers = {
    'mod',
    'shift',
    'alt',
    'ctrl',
    'meta',
    'cmd',
    'command',
    'control',
    'option',
  };

  /// Special key names the agent can press (letters and digits are also
  /// accepted); listed for editors that suggest them.
  static const List<String> namedKeys = [
    'enter',
    'tab',
    'escape',
    'space',
    'backspace',
    'delete',
    'arrowup',
    'arrowdown',
    'arrowleft',
    'arrowright',
    'home',
    'end',
    'pageup',
    'pagedown',
    'f1',
    'f2',
    'f3',
    'f4',
    'f5',
    'f6',
    'f7',
    'f8',
    'f9',
    'f10',
    'f11',
    'f12',
  ];

  /// Parses `+`-separated names, such as `mod+shift+a`: every part but the
  /// last must be one of [knownModifiers], and the last is the key. Case and
  /// surrounding spaces are ignored.
  ///
  /// Throws a [FormatException] for an empty part or an unknown modifier. The
  /// key itself is not checked here; the agent rejects a key it can't press.
  factory KeyChord.parse(String input) {
    final parts = input.split('+').map((p) => p.trim().toLowerCase()).toList();
    if (parts.any((p) => p.isEmpty)) {
      throw FormatException('empty key name in "$input"');
    }
    final key = parts.removeLast();
    for (final m in parts) {
      if (!knownModifiers.contains(m)) {
        throw FormatException('unknown modifier "$m" in "$input"');
      }
    }
    return KeyChord(parts, key);
  }

  /// The modifiers held down, lower case, in the order written.
  final List<String> modifiers;

  /// The key pressed while [modifiers] are held, lower case.
  final String key;

  @override
  String toString() => [...modifiers, key].join('+');
}
