import 'package:flutter/material.dart';

class DialogScreen extends StatefulWidget {
  const DialogScreen({super.key});

  @override
  State<DialogScreen> createState() => _DialogScreenState();
}

class _DialogScreenState extends State<DialogScreen> {
  String _result = '';

  Future<void> _open() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter a value'),
        content: Semantics(
          identifier: 'dialog_input',
          child: TextField(key: const ValueKey('dialog_input'), controller: controller, autofocus: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('OK')),
        ],
      ),
    );
    if (value != null && mounted) {
      setState(() => _result = value);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    } else {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dialog')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_result, key: const ValueKey('dialog_result')),
            const SizedBox(height: 16),
            Semantics(
              identifier: 'open_dialog',
              child: Tooltip(
                message: 'Opens a dialog',
                child: ElevatedButton(
                  key: const ValueKey('open_dialog'),
                  onPressed: _open,
                  child: const Text('Open dialog'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
