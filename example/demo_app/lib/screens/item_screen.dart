import 'package:flutter/material.dart';

/// Opened by the deep link `demo://app/item/<n>`.
class ItemScreen extends StatelessWidget {
  const ItemScreen({super.key, required this.item});

  final int item;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Item $item')),
    body: Center(child: Text('Item $item details', key: const ValueKey('item_details'))),
  );
}
