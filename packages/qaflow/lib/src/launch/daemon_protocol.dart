import 'dart:convert';

/// One frame of the `flutter run --machine` protocol.
class DaemonMessage {
  const DaemonMessage({this.event, this.params = const {}, this.id, this.result, this.error});

  final String? event;
  final Map<String, Object?> params;
  final int? id;
  final Object? result;
  final Object? error;
}

class DaemonProtocol {
  /// Returns null for anything that is not a `[{...}]` frame.
  static DaemonMessage? parseLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[{') || !trimmed.endsWith('}]')) return null;
    try {
      final list = jsonDecode(trimmed) as List;
      final map = (list.first as Map).cast<String, Object?>();
      return DaemonMessage(
        event: map['event'] as String?,
        params: (map['params'] as Map?)?.cast<String, Object?>() ?? const {},
        id: (map['id'] as num?)?.toInt(),
        result: map['result'],
        error: map['error'],
      );
    } on FormatException {
      return null;
    }
  }

  static String encodeRequest(int id, String method, Map<String, Object?> params) =>
      '${jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ])}\n';
}
