import 'package:flutter/material.dart';

import 'screens/dialog_screen.dart';
import 'screens/item_screen.dart';
import 'screens/list_screen.dart';
import 'screens/login_screen.dart';

class DemoApp extends StatelessWidget {
  const DemoApp({super.key, this.initialRoute = '/'});

  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QA Demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      initialRoute: initialRoute,
      routes: {
        '/': (_) => const LoginScreen(),
        '/list': (_) => const ListScreen(),
        '/dialog': (_) => const DialogScreen(),
      },
      onGenerateRoute: (settings) {
        final match = RegExp(r'^/item/(\d+)$').firstMatch(settings.name ?? '');
        if (match == null) return null;
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => ItemScreen(item: int.parse(match[1]!)),
        );
      },
    );
  }
}
