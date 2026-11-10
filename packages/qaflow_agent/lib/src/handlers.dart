import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'agent.dart';
import 'agent_platform.dart';
import 'args.dart';
import 'finder.dart';
import 'frames.dart';
import 'input/keyboard.dart';
import 'input/pointer.dart';
import 'input/text.dart';
import 'screenshot.dart';
import 'settle.dart';
import 'snapshot.dart';

class Handlers {
  static Future<Map<String, Object?>> dispatch(QaMethod method, Map<String, Object?> args) {
    switch (method) {
      case QaMethod.ping:
        return _ping(args);
      case QaMethod.elements:
        return Future.value({
          'nodes': Snapshot.elements(viewId: optInt(args, 'viewId'), all: optBool(args, 'all', orElse: false)),
        });
      case QaMethod.find:
        final selector = selectorArg(args) ?? (throw badRequest('selector is required'));
        return Future.value({
          'nodes': [for (final c in QaFinder.find(selector)) c.node.toJson()],
        });
      case QaMethod.elementAt:
        return Future.value(
          Snapshot.elementAt(Offset(requireDouble(args, 'x'), requireDouble(args, 'y')), optInt(args, 'viewId') ?? 0),
        );
      case QaMethod.screenshot:
        return _screenshot(args);
      case QaMethod.tap:
        Frames.requireRunning();
        return _tap(args);
      case QaMethod.longPress:
        Frames.requireRunning();
        return _longPress(args);
      case QaMethod.hover:
        Frames.requireRunning();
        return _hover(args);
      case QaMethod.drag:
        Frames.requireRunning();
        return _drag(args);
      case QaMethod.scroll:
        Frames.requireRunning();
        return _scroll(args);
      case QaMethod.pressKey:
        Frames.requireRunning();
        return _pressKey(args);
      case QaMethod.enterText:
        Frames.requireRunning();
        return _editText(args, (s) => TextSynth.enterText(s, requireString(args, 'text')));
      case QaMethod.eraseText:
        Frames.requireRunning();
        return _editText(args, (s) => TextSynth.eraseText(s, optInt(args, 'count') ?? 1));
      case QaMethod.setText:
        Frames.requireRunning();
        return _editText(args, (s) => TextSynth.setText(s, requireString(args, 'text')));
      case QaMethod.waitForIdle:
        Frames.requireRunning();
        final tier = optString(args, 'tier') ?? 'stable';
        if (tier != 'idle' && tier != 'stable') throw badRequest('tier must be idle or stable');
        return Settle.waitForIdle(
          timeout: Duration(milliseconds: optInt(args, 'timeoutMs') ?? 5000),
          tier: tier,
        );
      case QaMethod.back:
        Frames.requireRunning();
        return _back();
      case QaMethod.hideKeyboard:
        Frames.requireRunning();
        return _hideKeyboard();
      case QaMethod.setOrientation:
        return _setOrientation(args);
      case QaMethod.resetState:
        return _resetState();
    }
  }

  /// Resolves the target field once, before mutating it, and reports the
  /// node that resolution matched. Re-resolving the selector after the edit
  /// would be wrong: a text selector that matches the field's current
  /// content stops matching once the text changes, so a post-edit resolve
  /// spuriously reports not_found and the driver's retry-on-not_found would
  /// then apply the edit a second time.
  static Future<Map<String, Object?>> _editText(
    Map<String, Object?> args,
    String Function(EditableTextState state) edit,
  ) async {
    final selector = selectorArg(args);
    final (candidate, state) = await TextSynth.resolve(selector);
    final value = edit(state);
    await Frames.next();
    return {'node': candidate?.node.toJson(), 'value': value};
  }

  /// Resolves either a selector (with visibility and occlusion checks) or raw
  /// x,y into the point an input handler acts on.
  static (Offset, Candidate?) target(Map<String, Object?> args) {
    final selector = selectorArg(args);
    if (selector != null) {
      final c = QaFinder.resolveOne(selector);
      return (QaFinder.actionPoint(c), c);
    }
    final x = optDouble(args, 'x');
    final y = optDouble(args, 'y');
    if (x == null || y == null) throw badRequest('either selector or both x and y are required');
    return (Offset(x, y), null);
  }

  static int _viewIdFor(Map<String, Object?> args, Candidate? c) => c?.viewId ?? optInt(args, 'viewId') ?? 0;

  static Map<String, Object?> _nodeResult(Candidate? c) => {'node': c?.node.toJson()};

  static Future<Map<String, Object?>> _tap(Map<String, Object?> args) async {
    final count = optInt(args, 'count') ?? 1;
    if (count < 1 || count > 3) throw badRequest('count must be between 1 and 3');
    final (point, c) = target(args);
    final viewId = _viewIdFor(args, c);
    final buttons = optInt(args, 'buttons') ?? kPrimaryButton;
    for (var i = 0; i < count; i++) {
      if (i > 0) await Future<void>.delayed(PointerSynth.multiTapGap);
      await PointerSynth.tap(point, viewId, buttons: buttons);
    }
    return _nodeResult(c);
  }

  static Future<Map<String, Object?>> _longPress(Map<String, Object?> args) async {
    final (point, c) = target(args);
    final ms = optInt(args, 'durationMs');
    await PointerSynth.longPress(point, _viewIdFor(args, c), duration: Duration(milliseconds: ms ?? 600));
    return _nodeResult(c);
  }

  static Future<Map<String, Object?>> _hover(Map<String, Object?> args) async {
    if (AgentPlatform.isTouch) {
      throw QaException(QaErrorCode.unsupported, 'hover needs a mouse; this app runs on a touch platform');
    }
    final (point, c) = target(args);
    await PointerSynth.hover(point, _viewIdFor(args, c));
    return _nodeResult(c);
  }

  static Future<Map<String, Object?>> _drag(Map<String, Object?> args) async {
    final (point, c) = target(args);
    await PointerSynth.drag(
      point,
      Offset(optDouble(args, 'dx') ?? 0, optDouble(args, 'dy') ?? 0),
      _viewIdFor(args, c),
      steps: optInt(args, 'steps') ?? 10,
      duration: Duration(milliseconds: optInt(args, 'durationMs') ?? 300),
    );
    return _nodeResult(c);
  }

  static Future<Map<String, Object?>> _scroll(Map<String, Object?> args) async {
    var delta = Offset(optDouble(args, 'dx') ?? 0, optDouble(args, 'dy') ?? 0);
    final direction = optString(args, 'direction');
    if (direction != null) {
      final amount = optDouble(args, 'amount') ?? 300;
      delta = switch (direction) {
        'down' => Offset(0, amount),
        'up' => Offset(0, -amount),
        'right' => Offset(amount, 0),
        'left' => Offset(-amount, 0),
        _ => throw badRequest('direction must be up, down, left or right'),
      };
    }
    if (delta == Offset.zero) throw badRequest('scroll needs dx/dy or direction/amount');
    // No target: scroll at the centre of the first Scrollable on screen.
    final (point, c) = selectorArg(args) == null && optDouble(args, 'x') == null ? _firstScrollable() : target(args);
    await PointerSynth.scroll(point, delta, _viewIdFor(args, c));
    return _nodeResult(c);
  }

  static (Offset, Candidate?) _firstScrollable() {
    final c = QaFinder.resolveOne(const Selector(type: 'Scrollable', index: 0));
    return (QaFinder.actionPoint(c), c);
  }

  static Future<Map<String, Object?>> _screenshot(Map<String, Object?> args) async {
    final transfer = _screenshotTransfer(args);
    if (transfer == ScreenshotTransfer.file) {
      return Screenshot.capture(path: optString(args, 'path'));
    }
    final image = await Screenshot.render();
    return {
      'format': 'png',
      'data': base64Encode(image.bytes),
      'width': image.width,
      'height': image.height,
      'devicePixelRatio': image.devicePixelRatio,
    };
  }

  static ScreenshotTransfer _screenshotTransfer(Map<String, Object?> args) {
    final raw = optString(args, 'transfer');
    if (raw == null) return ScreenshotTransfer.inline;
    try {
      return ScreenshotTransfer.fromWire(raw);
    } on ArgumentError {
      throw badRequest('transfer must be "inline" or "file"');
    }
  }

  static Future<Map<String, Object?>> _pressKey(Map<String, Object?> args) async {
    final KeyChord chord;
    try {
      chord = KeyChord.parse(requireString(args, 'key'));
    } on FormatException catch (e) {
      throw badRequest(e.message);
    }
    final (:hadFocus, :handled) = await KeyboardSynth.press(chord);
    var submitted = false;
    // A focused widget that handled Enter itself (an autocomplete accepting
    // its highlighted item, say) has used the key; typing a newline or
    // submitting the field as well would apply it twice.
    if (chord.key == 'enter' && chord.modifiers.isEmpty && !handled) {
      final field = TextSynth.focusedEditable();
      if (field != null) {
        TextSynth.submit(field);
        submitted = true;
        await Frames.next();
      }
    }
    return {'delivered': true, 'hadFocus': hadFocus, 'submitted': submitted};
  }

  static Future<Map<String, Object?>> _back() async {
    if (!AgentPlatform.isAndroid()) {
      throw QaException(QaErrorCode.unsupported, 'back is only available on Android');
    }
    // The path the engine takes for the system back button.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final popped = await WidgetsBinding.instance.handlePopRoute();
    await Frames.next();
    return {'popped': popped};
  }

  static Future<Map<String, Object?>> _hideKeyboard() async {
    final focus = FocusManager.instance.primaryFocus;
    // A text field's focus node sits on the Focus widget inside EditableText.
    final hadFocus = focus?.context?.findAncestorStateOfType<EditableTextState>() != null;
    focus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await Frames.next();
    return {'hadFocus': hadFocus};
  }

  static const Map<String, DeviceOrientation> _orientations = {
    'portrait': DeviceOrientation.portraitUp,
    'landscapeLeft': DeviceOrientation.landscapeLeft,
    'landscapeRight': DeviceOrientation.landscapeRight,
  };

  static Future<Map<String, Object?>> _setOrientation(Map<String, Object?> args) async {
    if (!AgentPlatform.isIOS()) {
      throw QaException(QaErrorCode.unsupported, 'setOrientation through the agent is only used on iOS');
    }
    final name = requireString(args, 'orientation');
    final orientation =
        _orientations[name] ?? (throw badRequest('orientation must be portrait, landscapeLeft or landscapeRight'));
    await SystemChrome.setPreferredOrientations([orientation]);
    await Frames.next();
    await Frames.next();
    return {'orientation': name};
  }

  static Future<Map<String, Object?>> _resetState() async {
    final hook = QaAgent.onReset;
    if (hook == null) {
      throw QaException(QaErrorCode.unsupported, 'the app registered no reset hook; pass onReset to QaAgent.install');
    }
    await hook();
    return {'reset': true};
  }

  static Future<Map<String, Object?>> _ping(Map<String, Object?> args) async {
    final dir = optString(args, 'screenshotDirectory');
    if (dir != null) QaAgent.screenshotDirectory = dir;
    return {
      'platform': defaultTargetPlatform.name,
      'mode': kDebugMode ? 'debug' : 'profile',
      'dartVersion': Platform.version,
      'flutterVersion': FlutterVersion.version,
      'views': [
        for (final view in RendererBinding.instance.renderViews)
          {
            'viewId': view.flutterView.viewId,
            'width': view.size.width,
            'height': view.size.height,
            'devicePixelRatio': view.flutterView.devicePixelRatio,
          },
      ],
    };
  }
}
