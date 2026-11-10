import 'package:flutter/material.dart';

class ListScreen extends StatelessWidget {
  const ListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          // Endless animation so waitForIdle must fall back to the stable tier.
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          Semantics(
            identifier: 'go_dialog',
            child: IconButton(
              key: const ValueKey('go_dialog'),
              icon: const Icon(Icons.chat_bubble_outline),
              tooltip: 'Go to dialog screen',
              onPressed: () => Navigator.of(context).pushNamed('/dialog'),
            ),
          ),
        ],
      ),
      body: Semantics(
        identifier: 'item_list',
        child: ListView.builder(
          key: const ValueKey('item_list'),
          itemCount: 200,
          itemBuilder: (context, i) => Semantics(
            identifier: 'item_$i',
            child: ListTile(
              key: ValueKey('item_$i'),
              title: Text('Item $i'),
              trailing: Semantics(
                identifier: 'item_${i}_more',
                child: IconButton(
                  key: ValueKey('item_${i}_more'),
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () {},
                ),
              ),
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tapped Item $i'))),
            ),
          ),
        ),
      ),
    );
  }
}
