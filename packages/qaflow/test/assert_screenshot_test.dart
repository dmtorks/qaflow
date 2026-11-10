import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

import 'flow_test_support.dart';

List<int> png(int w, int h, {int shade = 200, (int, int)? black}) {
  final i = img.Image(width: w, height: h, numChannels: 4);
  img.fill(i, color: img.ColorRgba8(shade, shade, shade, 255));
  if (black != null) i.setPixelRgba(black.$1, black.$2, 0, 0, 0, 255);
  return img.encodePng(i);
}

void main() {
  const src = SourceRef('f.yaml', 1, 1);
  const exec = CommandExecutor();
  late Directory root;
  late Directory shots;
  late FakeAgent agent;
  late QaDriver driver;

  setUp(() {
    root = Directory.systemTemp.createTempSync('qa_app');
    shots = Directory(p.join(root.path, 'run', 'flows', 'login', 'screenshots'))..createSync(recursive: true);
    agent = FakeAgent();
    driver = testDriver(agent, shots.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  void screen(List<int> bytes, {double dpr = 1}) => agent.on[QaMethod.screenshot] = (_) => {
    'format': 'png',
    'data': base64Encode(bytes),
    'width': 4,
    'height': 4,
    'devicePixelRatio': dpr,
  };

  ExecutionContext ctx({BaselineMode mode = BaselineMode.record, bool project = true}) => ExecutionContext(
    driver: driver,
    scope: VariableScope(),
    screenshotDir: shots.path,
    viewWidth: 4,
    viewHeight: 4,
    baselines: project ? BaselineContext(appRoot: root.path, deviceKey: 'macos', flowSlug: 'login', mode: mode) : null,
  );

  String baselinePath() => p.join(root.path, '.qa', 'baselines', 'macos', 'login', 'home.png');
  const cmd = AssertScreenshot(source: src, screenshotName: 'home');

  test('a window that is not rendering yet is waited for, then captured', () async {
    screen(png(4, 4));
    var calls = 0;
    agent.on[QaMethod.waitForIdle] = (_) {
      if (++calls <= 2) throw QaException(QaErrorCode.notReady, 'lifecycle: hidden');
      return {'settled': 'idle'};
    };
    final out = await exec.execute(cmd, ctx());
    expect(out.note, 'baseline recorded');
    expect(File(baselinePath()).existsSync(), isTrue);
    expect(calls, greaterThan(2));
  });

  test('a window that never renders fails with not_ready after the step timeout', () async {
    screen(png(4, 4));
    agent.on[QaMethod.waitForIdle] = (_) => throw QaException(QaErrorCode.notReady, 'lifecycle: hidden');
    final watch = Stopwatch()..start();
    await expectLater(
      exec.execute(cmd, ctx()),
      throwsA(isA<QaStepFailure>().having((e) => e.last.code, 'code', QaErrorCode.notReady)),
    );
    expect(watch.elapsed, greaterThanOrEqualTo(driver.stepTimeout));
    expect(File(baselinePath()).existsSync(), isFalse);
  });

  test('record mode writes a missing baseline and warns', () async {
    screen(png(4, 4));
    final out = await exec.execute(cmd, ctx());
    expect(File(baselinePath()).existsSync(), isTrue);
    expect(out.warn, isTrue);
    expect(out.note, 'baseline recorded');
    expect(out.comparison!.outcome, ComparisonOutcome.recorded);
    expect(out.comparison!.baselinePath, '.qa/baselines/macos/login/home.png');
    expect(out.artifacts.map(p.basename), ['home.actual.png']);
  });

  test('a matching baseline passes and keeps a copy of the baseline', () async {
    File(baselinePath())
      ..createSync(recursive: true)
      ..writeAsBytesSync(png(4, 4));
    screen(png(4, 4));
    final out = await exec.execute(cmd, ctx());
    expect(out.warn, isFalse);
    expect(out.comparison!.outcome, ComparisonOutcome.passed);
    expect(out.comparison!.mismatchPercent, 0);
    expect(out.artifacts.map(p.basename), ['home.actual.png', 'home.baseline.png']);
  });

  test('a mismatch throws ScreenshotMismatch with a diff', () async {
    File(baselinePath())
      ..createSync(recursive: true)
      ..writeAsBytesSync(png(4, 4));
    screen(png(4, 4, black: (0, 0)));
    await expectLater(
      exec.execute(cmd, ctx()),
      throwsA(
        isA<ScreenshotMismatch>()
            .having((e) => e.message, 'message', '6.25% of pixels differ (threshold 0.1%)')
            .having((e) => e.comparison.outcome, 'outcome', ComparisonOutcome.failed)
            .having((e) => e.artifacts.map(p.basename), 'artifacts', [
              'home.actual.png',
              'home.baseline.png',
              'home.diff.png',
            ]),
      ),
    );
  });

  test('ignore blanks the matched widget', () async {
    File(baselinePath())
      ..createSync(recursive: true)
      ..writeAsBytesSync(png(4, 4));
    screen(png(4, 4, black: (1, 1)), dpr: 1);
    agent.on[QaMethod.find] = (_) => {
      'nodes': [fakeNode(key: 'clock', rect: const QaRect(1, 1, 1, 1), visibleRect: const QaRect(1, 1, 1, 1)).toJson()],
    };
    final out = await exec.execute(
      const AssertScreenshot(
        source: src,
        screenshotName: 'home',
        ignore: [FlowSelector(id: 'clock')],
      ),
      ctx(),
    );
    expect(out.comparison!.outcome, ComparisonOutcome.passed);
  });

  test('ignore rects are scaled by the capture\'s device pixel ratio', () async {
    File(baselinePath())
      ..createSync(recursive: true)
      ..writeAsBytesSync(png(8, 8));
    final actual = img.decodePng(Uint8List.fromList(png(8, 8)))!;
    for (final (x, y) in [(2, 2), (2, 3), (3, 2), (3, 3)]) {
      actual.setPixelRgba(x, y, 0, 0, 0, 255);
    }
    agent.on[QaMethod.find] = (_) => {
      'nodes': [fakeNode(key: 'clock', rect: const QaRect(1, 1, 1, 1), visibleRect: const QaRect(1, 1, 1, 1)).toJson()],
    };
    const ignoring = AssertScreenshot(
      source: src,
      screenshotName: 'home',
      ignore: [FlowSelector(id: 'clock')],
    );

    screen(img.encodePng(actual), dpr: 2);
    final out = await exec.execute(ignoring, ctx());
    expect(out.comparison!.outcome, ComparisonOutcome.passed);

    // At ratio 1 the same rect covers pixel (1,1) only.
    screen(img.encodePng(actual), dpr: 1);
    await expectLater(exec.execute(ignoring, ctx()), throwsA(isA<ScreenshotMismatch>()));
  });

  test('strict mode fails a missing baseline', () async {
    screen(png(4, 4));
    await expectLater(
      exec.execute(cmd, ctx(mode: BaselineMode.strict)),
      throwsA(
        isA<ScreenshotMismatch>().having(
          (e) => e.message,
          'message',
          'no baseline for "home" on macos (run with --baselines record or update)',
        ),
      ),
    );
    expect(File(baselinePath()).existsSync(), isFalse);
  });

  test('update mode overwrites and passes', () async {
    File(baselinePath())
      ..createSync(recursive: true)
      ..writeAsBytesSync(png(4, 4, shade: 10));
    screen(png(4, 4));
    final out = await exec.execute(cmd, ctx(mode: BaselineMode.update));
    expect(out.note, 'baseline updated');
    expect(out.warn, isFalse);
    expect(out.comparison!.outcome, ComparisonOutcome.updated);
    expect(File(baselinePath()).readAsBytesSync(), png(4, 4));
  });

  test('no project is a bad_request', () async {
    screen(png(4, 4));
    await expectLater(
      exec.execute(cmd, ctx(project: false)),
      throwsA(
        isA<QaException>()
            .having((e) => e.code, 'code', QaErrorCode.badRequest)
            .having(
              (e) => e.message,
              'message',
              'assertScreenshot needs a project (pass --config or --project) to know where baselines live',
            ),
      ),
    );
  });

  test('a name that is bad after substitution is a bad_request', () async {
    screen(png(4, 4));
    await expectLater(
      exec.execute(
        const AssertScreenshot(source: src, screenshotName: r'${N}'),
        ExecutionContext(
          driver: driver,
          scope: VariableScope({'N': 'a/b'}),
          screenshotDir: shots.path,
          viewWidth: 4,
          viewHeight: 4,
          baselines: BaselineContext(appRoot: root.path, deviceKey: 'macos', flowSlug: 'login'),
        ),
      ),
      throwsA(isA<QaException>().having((e) => e.code, 'code', QaErrorCode.badRequest)),
    );
  });
}
