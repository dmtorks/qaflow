import 'response.dart';

/// The version of the ext.qa.* wire format, incremented on every breaking
/// change. Sent in every [QaResponse] as `v`.
const int protocolVersion = 1;
