import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

// In your own app this file is lib/main_qa.dart, beside the lib/main.dart that
// release builds use. It is main.dart here so pub.dev finds the example.
void main() {
  QaAgent.install(onReset: () {});
  runApp(QaAgent.wrap(const MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('Hello'))),
    );
  }
}
