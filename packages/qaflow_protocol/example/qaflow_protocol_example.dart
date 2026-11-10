// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:qaflow_protocol/qaflow_protocol.dart';

void main() {
  const selector = Selector(text: 'Sign in', enabled: true);
  final request = jsonEncode({'selector': selector.toJson()});
  print('${QaMethod.tap.extensionName} <- $request');

  final reply = jsonEncode(QaResponse.failure(QaErrorCode.notFound, 'No widget matches').toJson());
  final response = QaResponse.fromJson((jsonDecode(reply) as Map).cast<String, Object?>());
  print('ok=${response.ok} code=${response.code?.wire} message=${response.message}');

  final decoded = Selector.fromJson((jsonDecode(request) as Map)['selector'].cast<String, Object?>());
  print('round trip text=${decoded.text}');
}
