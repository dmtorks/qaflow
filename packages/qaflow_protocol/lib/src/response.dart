import 'method.dart';
import 'version.dart';

/// Why the agent refused or failed a command, as sent in [QaResponse.code].
enum QaErrorCode {
  /// No widget matches the selector, or its `index` is out of range.
  notFound('not_found'),

  /// More than one widget matches a selector that must pick one.
  ambiguous('ambiguous'),

  /// The app can't act yet: no frames are being drawn, the target is
  /// disabled or not laid out, or no text field has focus.
  notReady('not_ready'),

  /// The target is outside the view or its scroll viewports.
  offScreen('off_screen'),

  /// Another widget covers the target, so a tap would not reach it.
  obscured('obscured'),

  /// The command's arguments are missing or invalid.
  badRequest('bad_request'),

  /// The command can't run on this platform or app setup, such as `back`
  /// off Android or a screenshot without `QaAgent.wrap`.
  unsupported('unsupported'),

  /// An unexpected failure inside the agent.
  internal('internal');

  const QaErrorCode(this.wire);

  /// The code as written on the wire, such as `not_found`.
  final String wire;

  /// The code whose [wire] form is [wire]. Throws an [ArgumentError] for an
  /// unknown one.
  static QaErrorCode fromWire(String wire) => values.firstWhere(
    (c) => c.wire == wire,
    orElse: () => throw ArgumentError.value(wire, 'wire', 'unknown QaErrorCode'),
  );
}

/// Thrown by the agent's handlers and by the driver when a response is not ok.
class QaException implements Exception {
  /// An error with a [code], a human-readable [message] and optional
  /// structured [details].
  QaException(this.code, this.message, {this.details = const {}});

  /// What kind of failure this is.
  final QaErrorCode code;

  /// A description of the failure for people.
  final String message;

  /// Extra machine-readable context, such as the match count for an
  /// ambiguous selector.
  final Map<String, Object?> details;

  @override
  String toString() => 'QaException(${code.wire}): $message';
}

/// The envelope every `ext.qa.*` call returns: either [ok] with a [result],
/// or not ok with a [code] and [message].
class QaResponse {
  /// A response with every field given. Prefer [QaResponse.success] and
  /// [QaResponse.failure], which fill in [v].
  const QaResponse({required this.ok, required this.v, this.result, this.code, this.message, this.details = const {}});

  /// A successful response carrying [result].
  factory QaResponse.success(Map<String, Object?> result) => QaResponse(ok: true, v: protocolVersion, result: result);

  /// A failed response with [code], [message] and optional [details].
  factory QaResponse.failure(QaErrorCode code, String message, [Map<String, Object?> details = const {}]) =>
      QaResponse(ok: false, v: protocolVersion, code: code, message: message, details: details);

  /// Reads the map written by [toJson].
  factory QaResponse.fromJson(Map<String, Object?> json) => QaResponse(
    ok: json['ok'] as bool,
    v: (json['v'] as num).toInt(),
    result: (json['result'] as Map?)?.cast<String, Object?>(),
    code: json['code'] == null ? null : QaErrorCode.fromWire(json['code'] as String),
    message: json['message'] as String?,
    details: (json['details'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  /// Whether the command succeeded.
  final bool ok;

  /// The [protocolVersion] of the side that wrote the response. The driver
  /// refuses an agent whose version differs from its own.
  final int v;

  /// The command's result when [ok]; its keys depend on the [QaMethod].
  final Map<String, Object?>? result;

  /// Why the command failed, when not [ok].
  final QaErrorCode? code;

  /// A description of the failure, when not [ok].
  final String? message;

  /// Extra context for a failure; empty when there is none.
  final Map<String, Object?> details;

  /// This response as JSON. A success writes `result` (an empty map when
  /// null); a failure writes `code`, `message` and, when non-empty,
  /// `details`.
  Map<String, Object?> toJson() => {
    'ok': ok,
    'v': v,
    if (ok) 'result': result ?? const <String, Object?>{},
    if (!ok) 'code': code!.wire,
    if (!ok) 'message': message,
    if (!ok && details.isNotEmpty) 'details': details,
  };
}
