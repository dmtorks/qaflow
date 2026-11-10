import 'package:flutter/gestures.dart';

import '../agent_platform.dart';
import '../frames.dart';

/// Synthesizes pointer events through GestureBinding.handlePointerEvent: touch
/// on iOS and Android, otherwise a mouse, which also feeds MouseTracker so
/// hover, enter and exit behave like real input.
class PointerSynth {
  static const int device = 0x5152;
  static PointerDeviceKind get kind => AgentPlatform.isTouch ? PointerDeviceKind.touch : PointerDeviceKind.mouse;

  /// Wheel scrolling always comes from a mouse: it is deterministic (no
  /// fling), and Scrollable handles pointer signals on every platform.
  static const int _wheelDevice = 0x5153;
  static final Stopwatch _clock = Stopwatch()..start();
  static final Set<int> _addedViews = <int>{};
  static final Set<int> _addedWheelViews = <int>{};
  static int _nextPointer = 100000;

  /// Pause between the taps of a multi-tap. Flutter recognises a double tap
  /// when the second press starts 40 to 300 ms after the first release
  /// (kDoubleTapMinTime, kDoubleTapTimeout).
  static const Duration multiTapGap = Duration(milliseconds: 100);

  static Duration get _now => _clock.elapsed;

  static void _dispatch(PointerEvent event) => GestureBinding.instance.handlePointerEvent(event);

  static Future<void> _frame() => Frames.next();

  static void _ensureAdded(int viewId, Offset position) {
    if (_addedViews.add(viewId)) {
      _dispatch(PointerAddedEvent(viewId: viewId, timeStamp: _now, kind: kind, device: device, position: position));
    }
  }

  static Future<void> hover(Offset position, int viewId) async {
    _ensureAdded(viewId, position);
    _dispatch(PointerHoverEvent(viewId: viewId, timeStamp: _now, kind: kind, device: device, position: position));
    await _frame();
  }

  /// A mouse is added and moved over the target first; a touch pointer is
  /// added by its down event.
  static Future<void> _approach(Offset position, int viewId) async {
    if (!AgentPlatform.isTouch) await hover(position, viewId);
  }

  static Future<void> tap(Offset position, int viewId, {int buttons = kPrimaryButton}) async {
    await _approach(position, viewId);
    final pointer = _nextPointer++;
    _dispatch(
      PointerDownEvent(
        viewId: viewId,
        timeStamp: _now,
        pointer: pointer,
        kind: kind,
        device: device,
        position: position,
        buttons: buttons,
      ),
    );
    // No frame wait before the release: on a slow device one frame can outlast
    // kLongPressTimeout, and a Tooltip's long-press recognizer then wins the tap.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _dispatch(
      PointerUpEvent(viewId: viewId, timeStamp: _now, pointer: pointer, kind: kind, device: device, position: position),
    );
    await _frame();
  }

  static Future<void> longPress(
    Offset position,
    int viewId, {
    Duration duration = const Duration(milliseconds: 600),
  }) async {
    await _approach(position, viewId);
    final pointer = _nextPointer++;
    _dispatch(
      PointerDownEvent(
        viewId: viewId,
        timeStamp: _now,
        pointer: pointer,
        kind: kind,
        device: device,
        position: position,
      ),
    );
    await _frame();
    await Future<void>.delayed(duration + const Duration(milliseconds: 100));
    _dispatch(
      PointerUpEvent(viewId: viewId, timeStamp: _now, pointer: pointer, kind: kind, device: device, position: position),
    );
    await _frame();
  }

  static Future<void> drag(
    Offset from,
    Offset by,
    int viewId, {
    int steps = 10,
    Duration duration = const Duration(milliseconds: 300),
  }) async {
    await _approach(from, viewId);
    final pointer = _nextPointer++;
    _dispatch(
      PointerDownEvent(viewId: viewId, timeStamp: _now, pointer: pointer, kind: kind, device: device, position: from),
    );
    await _frame();
    final delta = by / steps.toDouble();
    var position = from;
    for (var i = 0; i < steps; i++) {
      position += delta;
      _dispatch(
        PointerMoveEvent(
          viewId: viewId,
          timeStamp: _now,
          pointer: pointer,
          kind: kind,
          device: device,
          position: position,
          delta: delta,
        ),
      );
      await Future<void>.delayed(duration ~/ steps);
      await _frame();
    }
    _dispatch(
      PointerUpEvent(viewId: viewId, timeStamp: _now, pointer: pointer, kind: kind, device: device, position: position),
    );
    await _frame();
  }

  /// Mouse-wheel scrolling. Positive dy scrolls content up (moves toward the end).
  static Future<void> scroll(Offset at, Offset delta, int viewId, {int chunks = 5}) async {
    if (_addedWheelViews.add(viewId)) {
      _dispatch(
        PointerAddedEvent(
          viewId: viewId,
          timeStamp: _now,
          kind: PointerDeviceKind.mouse,
          device: _wheelDevice,
          position: at,
        ),
      );
    }
    final step = delta / chunks.toDouble();
    for (var i = 0; i < chunks; i++) {
      _dispatch(
        PointerScrollEvent(
          viewId: viewId,
          timeStamp: _now,
          kind: PointerDeviceKind.mouse,
          device: _wheelDevice,
          position: at,
          scrollDelta: step,
        ),
      );
      await _frame();
    }
  }
}
