import 'dart:convert';

import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../device/device.dart';

const hostProtocolVersion = 1;

/// This package's version, reported by `hello`. Kept in step with pubspec.yaml by a test.
const qaVersion = '0.1.2';

/// Why the host refused a `hello` from a client on another protocol version.
String protocolMismatchMessage({required int host, required int client}) =>
    'QA host speaks protocol $host; this qa speaks $client. Update qa on both machines.';

/// The close code and reason a second control connection is closed with.
const hostInUseCloseCode = 4000;
const hostInUseMessage = 'QA host is in use by another client';

/// [DeviceInfo] as the host sends it. [DeviceInfo.toJson] leaves out
/// `booted`, which the host's clients need.
Map<String, Object?> deviceInfoToWire(DeviceInfo info) => {...info.toJson(), 'booted': info.booted};

DeviceInfo deviceInfoFromWire(Map<String, Object?> json) =>
    DeviceInfo.fromJson(json).copyWith(booted: json['booted'] as bool? ?? true);

/// A failure reported by the host, carried as a JSON-RPC `error`.
class HostError implements Exception {
  const HostError(this.code, this.message, [this.data]);

  static const launchFailed = 1;
  static const protocolMismatch = 2;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  final int code;
  final String message;

  /// JSON-RPC `error.data`: `{qaCode}` carries a [QaException]'s code by name.
  final Map<String, Object?>? data;

  /// The [QaErrorCode] named in [data], else `internal`.
  QaErrorCode get qaCode => QaErrorCode.values.asNameMap()[data?['qaCode']] ?? QaErrorCode.internal;

  @override
  String toString() => 'HostError($code): $message';
}

/// One JSON-RPC 2.0 object, sent as a single text frame.
sealed class HostMessage {
  const HostMessage();

  /// Throws [FormatException] when [text] is not a request, response or notification.
  factory HostMessage.decode(String text) {
    final Object? json = jsonDecode(text);
    if (json is! Map) throw FormatException('host message is not an object', text);
    final id = json['id'];
    final method = json['method'];
    if (id != null && id is! int) throw FormatException('host message id is not an integer', text);
    if (method != null && method is! String) throw FormatException('host message method is not a string', text);
    final params = _map(json['params'], 'params', text) ?? const <String, Object?>{};
    if (method is String) {
      return id is int ? HostRequest(id, method, params) : HostNotification(method, params);
    }
    if (id is! int) throw FormatException('host message has neither method nor id', text);
    final error = _map(json['error'], 'error', text);
    if (error != null) {
      final code = error['code'];
      final message = error['message'];
      if (code is! int || message is! String) throw FormatException('host error is malformed', text);
      return HostResponse.failure(id, HostError(code, message, _map(error['data'], 'error data', text)));
    }
    return HostResponse.success(id, _map(json['result'], 'result', text) ?? const <String, Object?>{});
  }

  static Map<String, Object?>? _map(Object? value, String what, String text) {
    if (value == null) return null;
    if (value is! Map) throw FormatException('host message $what is not an object', text);
    return value.cast<String, Object?>();
  }

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());
}

class HostRequest extends HostMessage {
  const HostRequest(this.id, this.method, [this.params = const {}]);
  final int id;
  final String method;
  final Map<String, Object?> params;

  @override
  Map<String, Object?> toJson() => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};
}

class HostResponse extends HostMessage {
  const HostResponse.success(this.id, Map<String, Object?> this.result) : error = null;
  const HostResponse.failure(this.id, HostError this.error) : result = null;
  final int id;
  final Map<String, Object?>? result;
  final HostError? error;

  @override
  Map<String, Object?> toJson() => {
    'jsonrpc': '2.0',
    'id': id,
    if (error case final e?)
      'error': {'code': e.code, 'message': e.message, if (e.data != null) 'data': e.data}
    else
      'result': result,
  };
}

class HostNotification extends HostMessage {
  const HostNotification(this.method, [this.params = const {}]);
  final String method;
  final Map<String, Object?> params;

  @override
  Map<String, Object?> toJson() => {'jsonrpc': '2.0', 'method': method, 'params': params};
}
