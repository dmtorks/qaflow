import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

RunResult sampleResult({DeviceInfo? device}) => RunResult(
  device: device,
  runId: 'r1',
  project: 'demo <app>',
  mode: 'debug',
  startedAt: DateTime.utc(2026, 9, 29, 12),
  durationMs: 4200,
  flows: const [
    FlowResult(
      name: 'Login & out',
      file: '/work/flows/login.yaml',
      slug: 'login-out',
      tags: ['smoke'],
      status: FlowStatus.passed,
      durationMs: 1200,
      attempts: [
        AttemptResult(
          attempt: 1,
          status: 'passed',
          steps: [
            StepResult(id: '1', label: 'tapOn id: go', command: 'tapOn', status: StepStatus.passed, durationMs: 10),
          ],
        ),
      ],
    ),
    FlowResult(
      name: 'List',
      file: '/work/flows/list.yaml',
      slug: 'list',
      tags: [],
      status: FlowStatus.failed,
      durationMs: 3000,
      attempts: [
        AttemptResult(
          attempt: 1,
          status: 'failed',
          steps: [
            StepResult(
              id: '2',
              label: 'assertVisible text: "<Item>"',
              command: 'assertVisible',
              status: StepStatus.failed,
              durationMs: 2900,
              error: StepError('not_found', 'nothing matches "<Item>" & more'),
              artifacts: ['flows/list/screenshots/failure-2.png', 'flows/list/elements-2.json'],
              logTail: ['app said hi'],
            ),
            StepResult(id: '3', label: 'scroll', command: 'scroll', status: StepStatus.skipped, durationMs: 0),
          ],
        ),
      ],
    ),
    FlowResult(
      name: 'Later',
      file: '/work/flows/later.yaml',
      slug: 'later',
      tags: [],
      status: FlowStatus.notRun,
      durationMs: 0,
      attempts: [],
    ),
  ],
);

/// A one-flow result whose only step is [step].
RunResult resultWithStep(StepResult step) => RunResult(
  runId: 'r1',
  project: 'demo',
  mode: 'debug',
  startedAt: DateTime.utc(2026, 9, 29, 12),
  durationMs: 100,
  flows: [
    FlowResult(
      name: 'List',
      file: '/work/flows/list.yaml',
      slug: 'list',
      tags: const [],
      status: FlowStatus.failed,
      durationMs: 100,
      attempts: [
        AttemptResult(attempt: 1, status: 'failed', steps: [step]),
      ],
    ),
  ],
);

/// Writes flow files into a fresh temp folder.
class TempFlows {
  TempFlows() : dir = Directory.systemTemp.createTempSync('qa_flows').path;
  final String dir;

  String write(String relativePath, String content) {
    final file = File(p.join(dir, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return p.normalize(file.path);
  }

  void dispose() => Directory(dir).deleteSync(recursive: true);
}

/// A real PNG; the default [FakeAgent] screenshot is only a PNG header.
List<int> realPng({int w = 4, int h = 4, (int, int)? black}) {
  final i = img.Image(width: w, height: h, numChannels: 4);
  img.fill(i, color: img.ColorRgba8(200, 200, 200, 255));
  if (black != null) i.setPixelRgba(black.$1, black.$2, 0, 0, 0, 255);
  return img.encodePng(i);
}

void screenOf(FakeAgent agent, List<int> png) =>
    agent.on[QaMethod.screenshot] = (_) => {'format': 'png', 'data': base64Encode(png), 'devicePixelRatio': 1.0};

const List<int> pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

QaNode fakeNode({
  String type = 'Text',
  String? text,
  String? key,
  QaRect? rect = const QaRect(0, 0, 100, 20),
  QaRect? visibleRect = const QaRect(0, 0, 100, 20),
  bool? visible,
}) => QaNode(
  nodeId: Object.hash(type, text, key, rect?.x, rect?.y),
  parentId: null,
  type: type,
  text: text,
  key: key,
  semanticsId: null,
  label: null,
  rect: rect,
  viewId: 0,
  visible: visible ?? visibleRect != null,
  interactive: type != 'Text',
  enabled: true,
  visibleRect: visibleRect,
);

/// A scriptable agent transport. [on] overrides a method; otherwise: ping
/// reports macOS and one 800x600 view, waitForIdle is idle, elements is
/// empty, find matches `text`/`textRegex` against [visibleTexts],
/// screenshot returns [pngBytes], and everything else succeeds.
class FakeAgent implements QaTransport {
  final List<(QaMethod, Map<String, Object?>)> sent = [];
  final Set<String> visibleTexts = {};
  final Map<QaMethod, FutureOr<Map<String, Object?>> Function(Map<String, Object?> args)> on = {};

  List<Map<String, Object?>> argsFor(QaMethod method) => [
    for (final s in sent)
      if (s.$1 == method) s.$2,
  ];

  List<QaMethod> get methods => [for (final s in sent) s.$1];

  @override
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args) async {
    sent.add((method, args));
    final handler = on[method];
    if (handler != null) return QaResponse.success(await handler(args));
    switch (method) {
      case QaMethod.ping:
        return QaResponse.success({
          'platform': 'macOS',
          'mode': 'debug',
          'views': [
            {'viewId': 0, 'width': 800.0, 'height': 600.0, 'devicePixelRatio': 2.0},
          ],
        });
      case QaMethod.waitForIdle:
        return QaResponse.success({'settled': 'idle'});
      case QaMethod.elements:
        return QaResponse.success({'nodes': <Object?>[]});
      case QaMethod.find:
        final selector = (args['selector'] as Map).cast<String, Object?>();
        return QaResponse.success({
          'nodes': [
            for (final t in visibleTexts)
              if (_matches(selector, t)) fakeNode(text: t).toJson(),
          ],
        });
      case QaMethod.screenshot:
        return QaResponse.success({
          'format': 'png',
          'data': base64Encode(pngBytes),
          'width': 1,
          'height': 1,
          'devicePixelRatio': 1.0,
        });
      default:
        // A real agent always returns a matched node for element-targeted
        // methods (tap, longPress, hover, drag, ...); `null` here would make
        // QaDriver._node's cast throw for every such call.
        return QaResponse.success({'node': fakeNode().toJson(), 'value': ''});
    }
  }

  static bool _matches(Map<String, Object?> selector, String text) {
    final literal = selector['text'];
    final regex = selector['textRegex'];
    if (literal == null && regex == null) return false;
    if (literal != null && literal != text) return false;
    if (regex != null && !RegExp('^(?:$regex)\$').hasMatch(text)) return false;
    return true;
  }
}

QaDriver testDriver(FakeAgent agent, String screenshotDirectory) => QaDriver(
  agent,
  stepTimeout: const Duration(milliseconds: 300),
  pollInterval: const Duration(milliseconds: 5),
  screenshotDirectory: screenshotDirectory,
);

/// An AppSession over a [FakeAgent] that records lifecycle calls.
class FakeAppSession implements AppSession {
  FakeAppSession(this.agent, {this.supportsHotRestart = true}) : _driver = testDriver(agent, Directory.systemTemp.path);

  final FakeAgent agent;
  final QaDriver _driver;
  final List<String> calls = [];
  final StreamController<String> logLines = StreamController<String>.broadcast();
  bool running = false;
  DeviceInfo deviceInfo = DeviceInfo.desktop(DevicePlatform.macos, hostOsVersion: '');
  DeviceController controller = const UnsupportedDeviceController(DevicePlatform.macos);
  bool prepared = false;

  /// When set, prepareDevice reports booting this device first.
  DeviceInfo? boots;
  Object? failPrepare;

  /// Called while prepareDevice is in flight, after any onBooting.
  void Function()? onPrepare;

  @override
  Future<DeviceInfo> prepareDevice({void Function(DeviceInfo device)? onBooting}) async {
    calls.add('prepareDevice');
    if (failPrepare != null) throw failPrepare!;
    if (!prepared && boots != null) onBooting?.call(boots!);
    onPrepare?.call();
    await Future<void>.delayed(Duration.zero);
    prepared = true;
    return deviceInfo;
  }

  @override
  DeviceInfo? get device => prepared ? deviceInfo : null;

  @override
  DeviceController get deviceController => controller;
  Object? failStart;
  Object? failReset;
  Object? failStop;
  void Function()? onReset;

  @override
  final bool supportsHotRestart;

  @override
  QaDriver get driver => running ? _driver : throw StateError('the app is not running');

  @override
  bool get isRunning => running;

  @override
  Stream<String> get logs => logLines.stream;

  @override
  Future<void> start() async {
    calls.add('start');
    if (failStart != null) throw failStart!;
    running = true;
  }

  @override
  Future<void> reset({bool clearState = false}) async {
    calls.add(clearState ? 'reset(clearState)' : 'reset');
    if (failReset != null) throw failReset!;
    running = true;
    onReset?.call();
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
    final error = failStop;
    if (error != null) {
      failStop = null; // throws once, so a later legitimate stop still succeeds
      throw error;
    }
  }
}

class RecordingController implements DeviceController {
  final List<String> calls = [];
  Object? fail;
  void Function()? onCall;

  @override
  Future<void> setOrientation(ScreenOrientation orientation, QaDriver driver) async {
    onCall?.call();
    if (fail != null) throw fail!;
    calls.add('orientation ${orientation.name}');
  }

  @override
  Future<void> resetOrientation() async {
    onCall?.call();
    if (fail != null) throw fail!;
    calls.add('reset orientation');
  }

  @override
  Future<void> openLink(Uri link) async {
    onCall?.call();
    if (fail != null) throw fail!;
    calls.add('link $link');
  }
}
