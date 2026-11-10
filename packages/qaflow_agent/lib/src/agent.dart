import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'handlers.dart';
import 'screenshot.dart';

/// Entry point for the app under test. Use only from a dedicated QA
/// entrypoint such as lib/main_qa.dart so release builds never include it.
class QaAgent {
  static bool _installed = false;

  /// Where `screenshot` writes files when no path is given. The driver sets
  /// it through the `screenshotDirectory` argument of `ping`.
  static String screenshotDirectory = Directory.systemTemp.path;

  /// Called by `ext.qa.resetState` (the flow command `clearState`) to wipe
  /// the app's persisted state before the runner restarts it. Set through
  /// [install]; settable directly in tests.
  static FutureOr<void> Function()? onReset;

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

  /// Wraps the app in the RepaintBoundary that screenshots capture.
  static Widget wrap(Widget app) => RepaintBoundary(key: Screenshot.boundaryKey, child: app);

  /// Decodes [rawArgs], dispatches, and encodes a QaResponse. Never throws.
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
