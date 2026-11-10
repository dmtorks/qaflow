import 'package:qaflow_protocol/qaflow_protocol.dart';

/// Sends one ext.qa.* call and returns the agent's response, throwing
/// QaException both when the response is not ok and when the underlying
/// transport call itself fails (e.g. the VM service reports the isolate is
/// not ready). Callers only ever need to catch QaException.
abstract class QaTransport {
  Future<QaResponse> call(QaMethod method, Map<String, Object?> args);
}
