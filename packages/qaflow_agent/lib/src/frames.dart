import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

/// Bounds every wait for a rendered frame. Flutter stops producing frames
/// while the app lifecycle is `hidden`, `paused` or `detached` (a macOS
/// window that is minimized, fully covered, or on another Space reports
/// `hidden`), and `SchedulerBinding.endOfFrame` then never completes until
/// the app is visible again. Every frame wait in this package goes through
/// [next] instead, so a hidden window cannot stall a call forever.
class Frames {
  const Frames._();

  /// True while frames are disabled, so no `endOfFrame` await can complete
  /// on its own.
  static bool get paused => !SchedulerBinding.instance.framesEnabled;

  /// Completes `true` once the next frame ends, or `false` once [limit]
  /// passes without one. The timer is cancelled as soon as either happens,
  /// so a widget test never sees a pending timer at tear-down.
  static Future<bool> next({Duration limit = const Duration(seconds: 2)}) {
    final completer = Completer<bool>();
    final timer = Timer(limit, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    SchedulerBinding.instance.endOfFrame.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(true);
    });
    return completer.future;
  }

  /// Throws `not_ready` when frames are paused; a no-op otherwise.
  static void requireRunning() {
    if (!paused) return;
    final state = SchedulerBinding.instance.lifecycleState?.name ?? 'unknown';
    throw QaException(
      QaErrorCode.notReady,
      'the app is not rendering frames (lifecycle: $state); Flutter pauses '
      'rendering while every app window is minimized, fully covered or '
      'on another Space. Keep the app window visible during a run.',
    );
  }
}
