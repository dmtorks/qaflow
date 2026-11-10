import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../args.dart';
import '../frames.dart';

typedef KeyPair = (LogicalKeyboardKey, PhysicalKeyboardKey);

/// Synthesizes hardware key events through the same entry point the engine
/// uses, so HardwareKeyboard state, FocusManager, Shortcuts and Actions all see them.
class KeyboardSynth {
  static final Stopwatch _clock = Stopwatch()..start();

  static final Map<String, KeyPair> _table = {
    'a': (LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA),
    'b': (LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB),
    'c': (LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC),
    'd': (LogicalKeyboardKey.keyD, PhysicalKeyboardKey.keyD),
    'e': (LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
    'f': (LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF),
    'g': (LogicalKeyboardKey.keyG, PhysicalKeyboardKey.keyG),
    'h': (LogicalKeyboardKey.keyH, PhysicalKeyboardKey.keyH),
    'i': (LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI),
    'j': (LogicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyJ),
    'k': (LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK),
    'l': (LogicalKeyboardKey.keyL, PhysicalKeyboardKey.keyL),
    'm': (LogicalKeyboardKey.keyM, PhysicalKeyboardKey.keyM),
    'n': (LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN),
    'o': (LogicalKeyboardKey.keyO, PhysicalKeyboardKey.keyO),
    'p': (LogicalKeyboardKey.keyP, PhysicalKeyboardKey.keyP),
    'q': (LogicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyQ),
    'r': (LogicalKeyboardKey.keyR, PhysicalKeyboardKey.keyR),
    's': (LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS),
    't': (LogicalKeyboardKey.keyT, PhysicalKeyboardKey.keyT),
    'u': (LogicalKeyboardKey.keyU, PhysicalKeyboardKey.keyU),
    'v': (LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV),
    'w': (LogicalKeyboardKey.keyW, PhysicalKeyboardKey.keyW),
    'x': (LogicalKeyboardKey.keyX, PhysicalKeyboardKey.keyX),
    'y': (LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY),
    'z': (LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ),
    '0': (LogicalKeyboardKey.digit0, PhysicalKeyboardKey.digit0),
    '1': (LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1),
    '2': (LogicalKeyboardKey.digit2, PhysicalKeyboardKey.digit2),
    '3': (LogicalKeyboardKey.digit3, PhysicalKeyboardKey.digit3),
    '4': (LogicalKeyboardKey.digit4, PhysicalKeyboardKey.digit4),
    '5': (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
    '6': (LogicalKeyboardKey.digit6, PhysicalKeyboardKey.digit6),
    '7': (LogicalKeyboardKey.digit7, PhysicalKeyboardKey.digit7),
    '8': (LogicalKeyboardKey.digit8, PhysicalKeyboardKey.digit8),
    '9': (LogicalKeyboardKey.digit9, PhysicalKeyboardKey.digit9),
    'enter': (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
    'tab': (LogicalKeyboardKey.tab, PhysicalKeyboardKey.tab),
    'escape': (LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape),
    'space': (LogicalKeyboardKey.space, PhysicalKeyboardKey.space),
    'backspace': (LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace),
    'delete': (LogicalKeyboardKey.delete, PhysicalKeyboardKey.delete),
    'arrowup': (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
    'arrowdown': (LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown),
    'arrowleft': (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
    'arrowright': (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
    'home': (LogicalKeyboardKey.home, PhysicalKeyboardKey.home),
    'end': (LogicalKeyboardKey.end, PhysicalKeyboardKey.end),
    'pageup': (LogicalKeyboardKey.pageUp, PhysicalKeyboardKey.pageUp),
    'pagedown': (LogicalKeyboardKey.pageDown, PhysicalKeyboardKey.pageDown),
    'f1': (LogicalKeyboardKey.f1, PhysicalKeyboardKey.f1),
    'f2': (LogicalKeyboardKey.f2, PhysicalKeyboardKey.f2),
    'f3': (LogicalKeyboardKey.f3, PhysicalKeyboardKey.f3),
    'f4': (LogicalKeyboardKey.f4, PhysicalKeyboardKey.f4),
    'f5': (LogicalKeyboardKey.f5, PhysicalKeyboardKey.f5),
    'f6': (LogicalKeyboardKey.f6, PhysicalKeyboardKey.f6),
    'f7': (LogicalKeyboardKey.f7, PhysicalKeyboardKey.f7),
    'f8': (LogicalKeyboardKey.f8, PhysicalKeyboardKey.f8),
    'f9': (LogicalKeyboardKey.f9, PhysicalKeyboardKey.f9),
    'f10': (LogicalKeyboardKey.f10, PhysicalKeyboardKey.f10),
    'f11': (LogicalKeyboardKey.f11, PhysicalKeyboardKey.f11),
    'f12': (LogicalKeyboardKey.f12, PhysicalKeyboardKey.f12),
    'shift': (LogicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftLeft),
    'ctrl': (LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft),
    'alt': (LogicalKeyboardKey.altLeft, PhysicalKeyboardKey.altLeft),
    'meta': (LogicalKeyboardKey.metaLeft, PhysicalKeyboardKey.metaLeft),
  };

  static KeyPair lookup(String name) {
    final pair = _table[name.toLowerCase()];
    if (pair == null) throw badRequest('unknown key "$name"');
    return pair;
  }

  /// `mod` is Command on macOS and Control elsewhere; aliases collapse.
  static String canonicalModifier(String m) => switch (m) {
    'mod' => defaultTargetPlatform == TargetPlatform.macOS ? 'meta' : 'ctrl',
    'cmd' || 'command' => 'meta',
    'control' => 'ctrl',
    'option' => 'alt',
    _ => m,
  };

  /// Presses [chord]: modifiers down, the key down and up, modifiers up.
  /// [handled] is whether the focus system handled the key's down event (a
  /// Focus.onKeyEvent or a Shortcuts binding returning handled).
  static Future<({bool hadFocus, bool handled})> press(KeyChord chord) async {
    final modifierNames = chord.modifiers.map(canonicalModifier).toList();
    // Resolve every key name up front so a bad_request never dispatches a
    // down event: a modifier already pressed with no matching up would leave
    // HardwareKeyboard's state inconsistent for later presses in the test/run.
    final modifierKeys = [for (final m in modifierNames) lookup(m)];
    final key = lookup(chord.key);
    final hadFocus = FocusManager.instance.primaryFocus != null;
    for (final k in modifierKeys) {
      _send(ui.KeyEventType.down, k, null);
    }
    final handled = _send(ui.KeyEventType.down, key, _characterFor(chord.key, modifierNames.contains('shift')));
    _send(ui.KeyEventType.up, key, null);
    for (final k in modifierKeys.reversed) {
      _send(ui.KeyEventType.up, k, null);
    }
    await Frames.next();
    return (hadFocus: hadFocus, handled: handled);
  }

  // US-layout shifted digit row: no other layout is modeled.
  static const Map<String, String> _shiftedDigits = {
    '1': '!',
    '2': '@',
    '3': '#',
    '4': r'$',
    '5': '%',
    '6': '^',
    '7': '&',
    '8': '*',
    '9': '(',
    '0': ')',
  };

  static String? _characterFor(String name, bool shift) {
    if (shift && _shiftedDigits.containsKey(name)) return _shiftedDigits[name];
    if (name.length == 1) return shift ? name.toUpperCase() : name.toLowerCase();
    if (name == 'space') return ' ';
    return null;
  }

  /// Dispatches one key event and returns whether the focus system handled
  /// it.
  static bool _send(ui.KeyEventType type, KeyPair key, String? character) {
    // KeyEventManager is deprecated but is still the only entry point that
    // reaches FocusManager (it is installed as keyMessageHandler, not as a
    // HardwareKeyboard handler). synthesized: true makes it dispatch at once
    // instead of waiting for a raw key message. If this is removed in a later
    // SDK, fall back to handleKeyData(synthesized: false) followed by pushing
    // a flutter/keyevent message through ServicesBinding.instance.channelBuffers,
    // which is what flutter_test does.
    //
    // handleKeyData always returns false for a synthesized event and drops
    // the focus system's answer, so keyMessageHandler is wrapped for the
    // duration of this synchronous dispatch to read that answer.
    // ignore: deprecated_member_use
    final manager = ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    final original = manager.keyMessageHandler;
    var handled = false;
    // ignore: deprecated_member_use
    KeyMessageHandler? wrapper;
    if (original != null) {
      wrapper = (message) => handled = original(message);
      // ignore: deprecated_member_use
      manager.keyMessageHandler = wrapper;
    }
    try {
      // ignore: deprecated_member_use
      manager.handleKeyData(
        ui.KeyData(
          timeStamp: _clock.elapsed,
          type: type,
          physical: key.$2.usbHidUsage,
          logical: key.$1.keyId,
          character: character,
          synthesized: true,
        ),
      );
    } finally {
      // A handler that patched keyMessageHandler during dispatch keeps its patch.
      // ignore: deprecated_member_use
      if (wrapper != null && manager.keyMessageHandler == wrapper) manager.keyMessageHandler = original;
    }
    return handled;
  }
}
