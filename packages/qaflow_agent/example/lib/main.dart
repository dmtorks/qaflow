import 'package:flutter/material.dart';

// The app as release builds see it. Nothing here imports qaflow_agent;
// lib/main_qa.dart adds the agent around this same app.
void main() => runApp(const CounterApp());

/// Stands in for whatever your app persists: shared preferences, a database,
/// secure storage. lib/main_qa.dart clears it when a flow asks for a clean start.
class CounterStore {
  static int count = 0;
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: CounterPage());
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _count = CounterStore.count;

  void _increment() => setState(() => CounterStore.count = ++_count);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Counter')),
      body: Center(child: Text('Count: $_count', key: const ValueKey('count'))),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('increment'),
        onPressed: _increment,
        child: const Icon(Icons.add),
      ),
    );
  }
}
