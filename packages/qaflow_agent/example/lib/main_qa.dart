import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

import 'main.dart';

// The entrypoint QAFlow launches (flutter run -t lib/main_qa.dart).
void main() {
  QaAgent.install(onReset: () => CounterStore.count = 0);
  runApp(QaAgent.wrap(const CounterApp()));
}
