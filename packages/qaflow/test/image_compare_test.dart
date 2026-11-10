import 'package:image/image.dart' as img;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

img.Image solid(int w, int h, [int r = 200, int g = 200, int b = 200]) {
  final i = img.Image(width: w, height: h, numChannels: 4);
  img.fill(i, color: img.ColorRgba8(r, g, b, 255));
  return i;
}

void main() {
  test('identical images pass with 0%', () {
    final r = compareImages(solid(4, 4), solid(4, 4));
    expect(r.passed, isTrue);
    expect(r.mismatchPercent, 0);
    expect(r.sizeMismatch, isNull);
  });

  test('one differing pixel out of 16 is 6.25%', () {
    final actual = solid(4, 4)..setPixelRgba(1, 2, 0, 0, 0, 255);
    final r = compareImages(actual, solid(4, 4));
    expect(r.mismatchPercent, 6.25);
    expect(r.passed, isFalse);
    expect(compareImages(actual, solid(4, 4), thresholdPercent: 6.25).passed, isTrue);
    expect(r.describe(0.1), '6.25% of pixels differ (threshold 0.1%)');
  });

  test('a single differing pixel in a large image still fails at threshold 0', () {
    final actual = solid(1000, 1000)..setPixelRgba(5, 5, 0, 0, 0, 255);
    final r = compareImages(actual, solid(1000, 1000), thresholdPercent: 0);
    expect(r.passed, isFalse);
    expect(r.mismatchPercent, 0.01);
    expect(compareImages(actual, solid(1000, 1000), thresholdPercent: 0.1).passed, isTrue);
  });

  test('channel tolerance: 8 is the same, 9 differs', () {
    expect(compareImages(solid(2, 2, 208), solid(2, 2, 200)).mismatchPercent, 0);
    expect(compareImages(solid(2, 2, 209), solid(2, 2, 200)).mismatchPercent, 100);
  });

  test('different sizes fail without a diff', () {
    final r = compareImages(solid(3, 2), solid(2, 3));
    expect(r.passed, isFalse);
    expect(r.sizeMismatch, 'size 3×2 differs from baseline 2×3');
    expect(r.describe(0.1), 'size 3×2 differs from baseline 2×3');
    expect(r.diff, isNull);
  });

  test('an ignored rectangle hides the only difference and is painted blue in the diff', () {
    final actual = solid(4, 4)..setPixelRgba(1, 1, 0, 0, 0, 255);
    final r = compareImages(actual, solid(4, 4), ignore: const [PixelRect(1, 1, 2, 2)]);
    expect(r.passed, isTrue);
    expect(r.mismatchPercent, 0);
    final p = r.diff!.getPixel(1, 1);
    expect([p.r, p.g, p.b], [0, 0, 128]);
  });

  test('the diff paints differing pixels red and dims the rest', () {
    final actual = solid(2, 1)..setPixelRgba(0, 0, 0, 0, 0, 255);
    final d = compareImages(actual, solid(2, 1)).diff!;
    final red = d.getPixel(0, 0);
    expect([red.r, red.g, red.b, red.a], [255, 0, 0, 255]);
    final dim = d.getPixel(1, 0);
    expect(dim.r, lessThan(200));
    expect(dim.r, dim.g);
  });

  test('pixelRects scales, rounds outwards, clips and drops empty rects', () {
    final rects = pixelRects(
      [
        (x: 1.2, y: 0.5, width: 2.0, height: 1.0),
        (x: 9.0, y: 9.0, width: 5.0, height: 5.0),
        (x: 20, y: 20, width: 1, height: 1),
      ],
      2.0,
      20,
      20,
    );
    expect(rects.map((r) => [r.left, r.top, r.right, r.bottom]), [
      [2, 1, 7, 3],
      [18, 18, 20, 20],
    ]);
  });
}
