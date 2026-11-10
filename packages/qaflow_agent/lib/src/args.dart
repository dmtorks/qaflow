import 'package:qaflow_protocol/qaflow_protocol.dart';

QaException badRequest(String message, [Map<String, Object?> details = const {}]) =>
    QaException(QaErrorCode.badRequest, message, details: details);

Selector? selectorArg(Map<String, Object?> args) {
  final raw = args['selector'];
  if (raw == null) return null;
  if (raw is String) return Selector(text: raw);
  if (raw is! Map) throw badRequest('selector must be an object or a string');
  final selector = Selector.fromJson(raw.cast<String, Object?>());
  if (selector.isEmpty) throw badRequest('selector has no fields');
  return selector;
}

double? optDouble(Map<String, Object?> args, String name) {
  final v = args[name];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  throw badRequest('$name must be a number');
}

double requireDouble(Map<String, Object?> args, String name) =>
    optDouble(args, name) ?? (throw badRequest('$name is required'));

int? optInt(Map<String, Object?> args, String name) {
  final v = args[name];
  if (v == null) return null;
  if (v is num) return v.toInt();
  throw badRequest('$name must be an integer');
}

String? optString(Map<String, Object?> args, String name) {
  final v = args[name];
  if (v == null) return null;
  if (v is String) return v;
  throw badRequest('$name must be a string');
}

String requireString(Map<String, Object?> args, String name) =>
    optString(args, name) ?? (throw badRequest('$name is required'));

bool optBool(Map<String, Object?> args, String name, {required bool orElse}) {
  final v = args[name];
  if (v == null) return orElse;
  if (v is bool) return v;
  throw badRequest('$name must be a boolean');
}
