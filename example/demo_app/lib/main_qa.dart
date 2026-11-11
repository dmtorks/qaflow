import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

import 'app.dart';

void main() {
  // The demo keeps no persisted state, so clearState only needs the restart.
  QaAgent.install(onReset: () {});
  runApp(QaAgent.wrap(const DemoApp()));
}
