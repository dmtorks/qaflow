import '../flow/events.dart';

/// The parenthesised form of a `screenshot_mismatch` message: the trailing
/// ` (threshold t%)` becomes `, threshold t%`. Null for any other error.
String? mismatchDetail(StepError? error) {
  if (error == null || error.code != 'screenshot_mismatch') return null;
  final m = RegExp(r'^(.*) \((threshold [^)]*)\)$').firstMatch(error.message);
  return m == null ? error.message : '${m[1]}, ${m[2]}';
}
