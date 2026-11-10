import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'transport.dart';

/// A retried step that never succeeded within the step timeout.
class QaStepFailure implements Exception {
  QaStepFailure(this.label, this.last, this.snapshot);
  final String label;
  final QaException last;
  final List<QaNode>? snapshot;
  @override
  String toString() => 'QaStepFailure: $label failed after retries: ${last.code.wire}: ${last.message}';
}

/// What `elementAt` found: the innermost interesting widget under a point
/// and the agent's selector candidates for it, most specific first.
class ElementHit {
  const ElementHit({required this.node, required this.selectors});
  final QaNode node;
  final List<Selector> selectors;
}

/// A screenshot and the device pixel ratio it was taken at.
class ScreenshotCapture {
  const ScreenshotCapture(this.png, this.devicePixelRatio);
  final Uint8List png;
  final double devicePixelRatio;
}

/// Typed wrapper over the agent's extensions with retry rules.
class QaDriver {
  QaDriver(
    this.transport, {
    this.stepTimeout = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 100),
    this.settleTimeout = const Duration(seconds: 5),
    String? screenshotDirectory,
    void Function(String message)? log,
    this.inlineScreenshotsOnly = false,
  }) : screenshotDirectory = screenshotDirectory ?? Directory.systemTemp.path,
       _log = log ?? ((_) {});

  final QaTransport transport;
  final Duration stepTimeout;
  final Duration pollInterval;
  final Duration settleTimeout;

  /// Where inline screenshots are written when no explicit path is given.
  final String screenshotDirectory;
  final void Function(String) _log;

  /// Set when the app runs on another machine (a `qa host`): the agent
  /// cannot write to this machine's files, so [screenshot] never asks it
  /// for `file` transfer.
  final bool inlineScreenshotsOnly;

  Future<QaResponse> ping({String? screenshotDirectory}) =>
      transport.call(QaMethod.ping, {'screenshotDirectory': ?screenshotDirectory});

  /// Returns `idle`, `stable` or `timeout`. A timeout is logged, not thrown.
  Future<String> waitForIdle({Duration? timeout}) async {
    final limit = timeout ?? settleTimeout;
    final r = await transport.call(QaMethod.waitForIdle, {'timeoutMs': limit.inMilliseconds});
    final settled = _requireString(r.result!, 'settled');
    if (settled == 'timeout') _log('waitForIdle: UI did not settle within $limit, continuing');
    return settled;
  }

  Future<ScreenshotCapture> screenshotCapture() async {
    final r = await transport.call(QaMethod.screenshot, {'transfer': ScreenshotTransfer.inline.name});
    final ratio = (r.result!['devicePixelRatio'] as num?)?.toDouble() ?? 1.0;
    return ScreenshotCapture(base64Decode(_requireString(r.result!, 'data')), ratio);
  }

  /// PNG bytes of the app window, transferred inline (works under the macOS
  /// App Sandbox).
  Future<Uint8List> screenshotBytes() async => (await screenshotCapture()).png;

  /// Returns the local file path of the screenshot. `inline` (the default)
  /// asks the agent for base64 PNG bytes and writes them here, so it works
  /// even when the app under test cannot write its own files (e.g. the
  /// macOS App Sandbox). `file` has the agent write the file itself, which
  /// needs an unsandboxed app or a file-access entitlement.
  Future<String> screenshot({String? path, ScreenshotTransfer transfer = ScreenshotTransfer.inline}) async {
    if (transfer == ScreenshotTransfer.file && !inlineScreenshotsOnly) {
      final r = await transport.call(QaMethod.screenshot, {'transfer': transfer.name, 'path': ?path});
      return _requireString(r.result!, 'path');
    }
    final bytes = await screenshotBytes();
    final file = File(path ?? p.join(screenshotDirectory, 'qa_${DateTime.now().millisecondsSinceEpoch}.png'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  static const Set<QaErrorCode> retryable = {
    QaErrorCode.notFound,
    QaErrorCode.ambiguous,
    QaErrorCode.notReady,
    QaErrorCode.offScreen,
    QaErrorCode.obscured,
  };

  /// Settles, then runs [attempt], retrying both while the app is not
  /// rendering frames yet (`not_ready`), until [stepTimeout]; then throws a
  /// [QaStepFailure] with the last error.
  Future<T> untilReady<T>(String label, Future<T> Function() attempt) =>
      _retry(label, attempt, retryOn: const {QaErrorCode.notReady});

  Future<T> _retry<T>(
    String label,
    Future<T> Function() attempt, {
    Duration? timeout,
    Set<QaErrorCode> retryOn = retryable,
  }) async {
    final deadline = DateTime.now().add(timeout ?? stepTimeout);
    QaException? last;
    while (true) {
      try {
        await waitForIdle();
        return await attempt();
      } on QaException catch (e) {
        if (!retryOn.contains(e.code)) rethrow;
        last = e;
        _log('$label: ${e.code.wire}: ${e.message}, retrying');
      }
      if (DateTime.now().isAfter(deadline)) {
        List<QaNode>? snapshot;
        try {
          snapshot = await elements();
        } catch (_) {}
        throw QaStepFailure(label, last, snapshot);
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Reads a required String field from an agent response, raising a QaException
  /// with [QaErrorCode.internal] instead of a raw TypeError when it is missing
  /// or the wrong type.
  static String _requireString(Map<String, Object?> result, String field) {
    final value = result[field];
    if (value is String) return value;
    throw QaException(
      QaErrorCode.internal,
      'expected a String for "$field" in the agent response, got ${value.runtimeType}',
    );
  }

  QaNode _node(QaResponse r) => QaNode.fromJson((r.result!['node'] as Map).cast<String, Object?>());

  List<QaNode> _nodes(QaResponse r) => [
    for (final n in r.result!['nodes'] as List) QaNode.fromJson((n as Map).cast<String, Object?>()),
  ];

  Future<List<QaNode>> elements({bool all = false}) async =>
      _nodes(await transport.call(QaMethod.elements, {'all': all}));

  Future<List<QaNode>> find(Selector s) async => _nodes(await transport.call(QaMethod.find, {'selector': s.toJson()}));

  /// The innermost interesting widget at ([x], [y]) in logical pixels, with
  /// the agent's selector candidates. Not retried: `not_found` means there
  /// is nothing selectable at that point, which the caller shows as such.
  Future<ElementHit> elementAt(double x, double y) async {
    final r = await transport.call(QaMethod.elementAt, {'x': x, 'y': y});
    return ElementHit(
      node: _node(r),
      selectors: [
        for (final s in r.result!['selectors'] as List) Selector.fromJson((s as Map).cast<String, Object?>()),
      ],
    );
  }

  Future<QaNode> tap(Selector s) =>
      _retry('tap $s', () async => _node(await transport.call(QaMethod.tap, {'selector': s.toJson()})));

  Future<QaNode> doubleTap(Selector s) => _retry(
    'doubleTap $s',
    () async => _node(await transport.call(QaMethod.tap, {'selector': s.toJson(), 'count': 2})),
  );

  /// Coordinate actions act immediately: no settle, no retry. Callers settle
  /// first when they need to.
  Future<void> tapAt(double x, double y, {int count = 1}) =>
      transport.call(QaMethod.tap, {'x': x, 'y': y, if (count != 1) 'count': count});

  Future<void> longPressAt(double x, double y) => transport.call(QaMethod.longPress, {'x': x, 'y': y});

  Future<void> dragAt(double x, double y, {double dx = 0, double dy = 0, int? durationMs}) =>
      transport.call(QaMethod.drag, {'x': x, 'y': y, 'dx': dx, 'dy': dy, 'durationMs': ?durationMs});

  /// The agent waits a frame after each scroll chunk, so a find straight
  /// after this sees the rebuilt list.
  Future<void> scrollAt(double x, double y, {double dx = 0, double dy = 0}) =>
      transport.call(QaMethod.scroll, {'x': x, 'y': y, 'dx': dx, 'dy': dy});

  /// Runs the app's reset hook. Not retried: an app without a hook answers
  /// `unsupported`, and a hook must not run twice.
  Future<void> resetState() => transport.call(QaMethod.resetState, const {});

  Future<QaNode> longPress(Selector s) =>
      _retry('longPress $s', () async => _node(await transport.call(QaMethod.longPress, {'selector': s.toJson()})));

  Future<QaNode> hover(Selector s) =>
      _retry('hover $s', () async => _node(await transport.call(QaMethod.hover, {'selector': s.toJson()})));

  Future<QaNode> drag(Selector s, {double dx = 0, double dy = 0}) => _retry(
    'drag $s',
    () async => _node(await transport.call(QaMethod.drag, {'selector': s.toJson(), 'dx': dx, 'dy': dy})),
  );

  Future<void> scroll({Selector? selector, double dx = 0, double dy = 0}) => _retry(
    'scroll ${selector ?? ''}',
    () => transport.call(QaMethod.scroll, {if (selector != null) 'selector': selector.toJson(), 'dx': dx, 'dy': dy}),
  );

  Future<void> scrollDirection({Selector? selector, required String direction, double amount = 300}) => _retry(
    'scroll $direction ${selector ?? ''}',
    () => transport.call(QaMethod.scroll, {
      if (selector != null) 'selector': selector.toJson(),
      'direction': direction,
      'amount': amount,
    }),
  );

  Future<String> _edit(QaMethod method, Map<String, Object?> args, Selector? selector) =>
      _retry('${method.name} ${selector ?? '(focused)'}', () async {
        final r = await transport.call(method, {if (selector != null) 'selector': selector.toJson(), ...args});
        return r.result!['value'] as String;
      });

  Future<String> enterText(String text, {Selector? selector}) => _edit(QaMethod.enterText, {'text': text}, selector);

  Future<String> eraseText(int count, {Selector? selector}) => _edit(QaMethod.eraseText, {'count': count}, selector);

  Future<String> setText(String text, {Selector? selector}) => _edit(QaMethod.setText, {'text': text}, selector);

  /// Not retried: a key press either reaches the focus tree or it does not.
  Future<void> pressKey(String chord) async {
    await waitForIdle();
    await transport.call(QaMethod.pressKey, {'key': chord});
  }

  /// Android system back; true when a route was popped. Not retried.
  Future<bool> back() async {
    await waitForIdle();
    final r = await transport.call(QaMethod.back, const {});
    return r.result?['popped'] == true;
  }

  /// Unfocuses the focused field and hides the soft keyboard, then settles
  /// so the keyboard has animated out. True when a text field had focus.
  Future<bool> hideKeyboard() async {
    final r = await transport.call(QaMethod.hideKeyboard, const {});
    await waitForIdle();
    return r.result?['hadFocus'] == true;
  }

  /// iOS only: rotates the app through its preferred orientations.
  Future<void> setOrientation(String orientation) async {
    await transport.call(QaMethod.setOrientation, {'orientation': orientation});
    await waitForIdle();
  }

  Future<QaNode> assertVisible(Selector s, {Duration? timeout}) => _retry('assertVisible $s', () async {
    final hits = await find(s);
    final visible = hits.where((n) => n.visible).toList();
    if (visible.isEmpty) {
      throw QaException(
        hits.isEmpty ? QaErrorCode.notFound : QaErrorCode.offScreen,
        hits.isEmpty ? 'nothing matches $s' : '${hits.length} match(es) but none visible',
      );
    }
    return visible.first;
  }, timeout: timeout);

  Future<void> assertNotVisible(Selector s, {Duration? timeout}) => _retry('assertNotVisible $s', () async {
    final visible = (await find(s)).where((n) => n.visible).toList();
    if (visible.isNotEmpty) {
      throw QaException(QaErrorCode.notReady, '${visible.length} match(es) still visible for $s');
    }
  }, timeout: timeout);
}
