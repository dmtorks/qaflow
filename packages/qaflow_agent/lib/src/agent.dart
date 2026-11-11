import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'handlers.dart';
import 'screenshot.dart';

/// The QAFlow agent for the app under test.
///
/// Use it only from a dedicated QA entrypoint, `lib/main_qa.dart`, so the
/// `lib/main.dart` that release builds compile never imports it:
///
/// ```dart
/// void main() {
///   QaAgent.install(onReset: resetAppState);
///   runApp(QaAgent.wrap(const MyApp()));
/// }
/// ```
class QaAgent {
  static bool _installed = false;

  /// Where `screenshot` writes files when no path is given. The driver sets
  /// it through the `screenshotDirectory` argument of `ping`.
  static String screenshotDirectory = Directory.systemTemp.path;

  /// Called by `ext.qa.resetState` (the flow command `clearState`) to wipe
  /// the app's persisted state before the runner restarts it. Set through
  /// [install]; settable directly in tests.
  static FutureOr<void> Function()? onReset;

  /// Registers the `ext.qa.*` service extensions the QAFlow driver calls.
  ///
  /// Call it once in `lib/main_qa.dart`, before `runApp`. Later calls only
  /// replace [onReset] when one is given.
  ///
  /// [onReset] wipes the app's persisted state (preferences, databases,
  /// secure storage) when a flow uses `clearState`; the runner restarts the
  /// app after it completes. Without it, `clearState` fails.
  ///
  /// Throws a [StateError] in release builds, which have no VM service.
  static void install({FutureOr<void> Function()? onReset}) {
    if (kReleaseMode) {
      throw StateError('qaflow_agent must not be compiled into release builds');
    }
    if (onReset != null) QaAgent.onReset = onReset;
    if (_installed) return;
    _installed = true;
    for (final method in QaMethod.values) {
      developer.registerExtension(method.extensionName, (_, params) async {
        final json = await handle(method, params['args']);
        return developer.ServiceExtensionResponse.result(json);
      });
    }
  }

  /// Wraps [app] in the RepaintBoundary that screenshots capture.
  ///
  /// Use it around the widget passed to `runApp`. Without it,
  /// `takeScreenshot` and `assertScreenshot` fail.
  static Widget wrap(Widget app) => RepaintBoundary(key: Screenshot.boundaryKey, child: app);

  /// Runs one agent [method] with JSON-encoded [rawArgs] and returns the
  /// JSON-encoded QaResponse, as the service extension would. Never throws.
  ///
  /// The registered extensions call this. Apps don't need it; it is public
  /// so widget tests can drive the agent without a VM service.
  static Future<String> handle(QaMethod method, String? rawArgs) async {
    Map<String, Object?> args;
    try {
      final decoded = rawArgs == null || rawArgs.isEmpty ? <String, Object?>{} : jsonDecode(rawArgs);
      if (decoded is! Map) throw const FormatException('args must be a JSON object');
      args = decoded.cast<String, Object?>();
    } on FormatException catch (e) {
      return jsonEncode(QaResponse.failure(QaErrorCode.badRequest, 'invalid args: ${e.message}').toJson());
    }
    try {
      final result = await Handlers.dispatch(method, args);
      return jsonEncode(QaResponse.success(result).toJson());
    } on QaException catch (e) {
      return jsonEncode(QaResponse.failure(e.code, e.message, e.details).toJson());
    } catch (e, stack) {
      return jsonEncode(QaResponse.failure(QaErrorCode.internal, e.toString(), {'stack': stack.toString()}).toJson());
    }
  }
}
