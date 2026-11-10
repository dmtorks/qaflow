import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// A pixel rectangle; [right] and [bottom] are exclusive.
class PixelRect {
  const PixelRect(this.left, this.top, this.right, this.bottom);
  final int left;
  final int top;
  final int right;
  final int bottom;

  bool contains(int x, int y) => x >= left && x < right && y >= top && y < bottom;
}

class ComparisonResult {
  const ComparisonResult({required this.passed, required this.mismatchPercent, this.sizeMismatch, this.diff});

  final bool passed;

  /// Differing pixels as a percentage of all pixels, rounded to two decimals
  /// for display; a non-zero difference is never shown as less than 0.01.
  /// [passed] is decided on the exact value, not this rounded one.
  final double mismatchPercent;

  /// Set when the sizes differ; nothing else is compared then.
  final String? sizeMismatch;

  /// The actual image dimmed, differing pixels red, ignored areas dark blue.
  final img.Image? diff;

  String describe(double thresholdPercent) =>
      sizeMismatch ??
      '${formatPercent(mismatchPercent)}% of pixels differ (threshold ${formatPercent(thresholdPercent)}%)';
}

/// A percentage as messages and reports show it: `3`, not `3.0`; `0.27`.
String formatPercent(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

ComparisonResult compareImages(
  img.Image actual,
  img.Image baseline, {
  List<PixelRect> ignore = const [],
  double thresholdPercent = 0.1,
  int channelTolerance = 8,
}) {
  if (actual.width != baseline.width || actual.height != baseline.height) {
    return ComparisonResult(
      passed: false,
      mismatchPercent: 100,
      sizeMismatch: 'size ${actual.width}×${actual.height} differs from baseline ${baseline.width}×${baseline.height}',
    );
  }
  final a = _rgba8(actual);
  final b = _rgba8(baseline);
  final diff = img.Image(width: a.width, height: a.height, numChannels: 4);
  var differing = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      var ignored = false;
      for (final r in ignore) {
        if (r.contains(x, y)) {
          ignored = true;
          break;
        }
      }
      if (ignored) {
        diff.setPixelRgba(x, y, 0, 0, 128, 255);
        continue;
      }
      final pa = a.getPixel(x, y);
      final pb = b.getPixel(x, y);
      final differs =
          (pa.r - pb.r).abs() > channelTolerance ||
          (pa.g - pb.g).abs() > channelTolerance ||
          (pa.b - pb.b).abs() > channelTolerance ||
          (pa.a - pb.a).abs() > channelTolerance;
      if (differs) {
        differing++;
        diff.setPixelRgba(x, y, 255, 0, 0, 255);
      } else {
        final grey = ((pa.r + pa.g + pa.b) / 3 * 0.3).round();
        diff.setPixelRgba(x, y, grey, grey, grey, 255);
      }
    }
  }
  final total = a.width * a.height;
  final exact = total == 0 ? 0.0 : differing * 100 / total;
  final rounded = (exact * 100).round() / 100;
  final percent = differing > 0 && rounded == 0 ? 0.01 : rounded;
  return ComparisonResult(passed: exact <= thresholdPercent, mismatchPercent: percent, diff: diff);
}

/// [logicalRects] in logical pixels, scaled by [devicePixelRatio], rounded
/// outwards and clipped to the image; empty results are dropped.
List<PixelRect> pixelRects(
  Iterable<({double x, double y, double width, double height})> logicalRects,
  double devicePixelRatio,
  int imageWidth,
  int imageHeight,
) => [for (final r in logicalRects) ?_clip(r, devicePixelRatio, imageWidth, imageHeight)];

PixelRect? _clip(({double x, double y, double width, double height}) r, double dpr, int w, int h) {
  final left = math.max(0, (r.x * dpr).floor());
  final top = math.max(0, (r.y * dpr).floor());
  final right = math.min(w, ((r.x + r.width) * dpr).ceil());
  final bottom = math.min(h, ((r.y + r.height) * dpr).ceil());
  return right > left && bottom > top ? PixelRect(left, top, right, bottom) : null;
}

img.Image _rgba8(img.Image i) =>
    i.format == img.Format.uint8 && i.numChannels == 4 ? i : i.convert(format: img.Format.uint8, numChannels: 4);
