import 'package:flutter/scheduler.dart';

import 'finder.dart';
import 'frames.dart';

/// Waits for the UI to stop changing.
///
/// Tier `idle`: no frame scheduled and no transient callbacks.
/// Tier `stable`: when frames keep coming (endless animations), returns once
/// the element snapshot is unchanged for three consecutive frames and at
/// least [stableMinWait] has elapsed since waitForIdle started.
/// Otherwise returns `timeout` after [timeout]; callers proceed with a warning.
class Settle {
  /// Minimum time the stable tier holds an unchanged hash before it accepts
  /// it as settled. A short opacity-only transition can produce an unchanged
  /// element snapshot (rects unchanged, only paint alpha animating) well
  /// before the animation actually finishes, so three equal-hash frames
  /// alone is not enough evidence of settling.
  static const stableMinWait = Duration(milliseconds: 500);

  static Future<Map<String, Object?>> waitForIdle({
    Duration timeout = const Duration(seconds: 5),
    String tier = 'stable',
  }) async {
    final scheduler = SchedulerBinding.instance;
    // Bounded by the full timeout: no frame has happened yet, so there is no
    // frame-timestamp elapsed time to subtract.
    if (!await Frames.next(limit: timeout)) {
      Frames.requireRunning();
      return {'settled': 'timeout', 'elapsedMs': timeout.inMilliseconds, 'frames': 0};
    }
    final start = scheduler.currentSystemFrameTimeStamp;
    var frames = 1;
    int? lastHash;
    var stableFrames = 1;

    Map<String, Object?> result(String settled) => {
      'settled': settled,
      'elapsedMs': (scheduler.currentSystemFrameTimeStamp - start).inMilliseconds,
      'frames': frames,
    };

    while (true) {
      if (!scheduler.hasScheduledFrame && scheduler.transientCallbackCount == 0) {
        return result('idle');
      }
      if (tier == 'stable') {
        final hash = _snapshotHash();
        if (hash == lastHash) {
          stableFrames++;
          final elapsed = scheduler.currentSystemFrameTimeStamp - start;
          if (stableFrames >= 3 && elapsed >= stableMinWait) return result('stable');
        } else {
          stableFrames = 1;
          lastHash = hash;
        }
      }
      final elapsed = scheduler.currentSystemFrameTimeStamp - start;
      if (elapsed >= timeout) return result('timeout');
      // Bounded by what is left of timeout, measured in frame-timestamp time
      // (which only advances while frames actually arrive): if the app goes
      // hidden mid-wait, this still gives up within timeout of when the last
      // real frame landed, rather than waiting on a frame that never comes.
      if (!await Frames.next(limit: timeout - elapsed)) {
        Frames.requireRunning();
        // No new frame landed, so currentSystemFrameTimeStamp is still the
        // last real one; report the timeout that was actually reached
        // rather than that stale, smaller elapsed value.
        return {'settled': 'timeout', 'elapsedMs': timeout.inMilliseconds, 'frames': frames};
      }
      frames++;
    }
  }

  static int _snapshotHash() => Object.hashAll([
    for (final c in QaFinder.collect())
      Object.hash(
        c.node.type,
        c.node.text,
        c.node.rect?.x,
        c.node.rect?.y,
        c.node.rect?.width,
        c.node.rect?.height,
        c.node.visible,
      ),
  ]);
}
