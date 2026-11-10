import 'package:demo_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('login with the right password reaches the list', (tester) async {
    await tester.pumpWidget(const DemoApp());
    expect(find.text('Welcome'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('username')), 'alice');
    await tester.enterText(find.byKey(const ValueKey('password')), 'wrong');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Wrong password'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('password')), 'secret');
    await tester.tap(find.byKey(const ValueKey('login')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Item 0'), findsOneWidget);
  });

  testWidgets('dialog writes its value to the result text', (tester) async {
    await tester.pumpWidget(const DemoApp(initialRoute: '/dialog'));
    await tester.tap(find.byKey(const ValueKey('open_dialog')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a value'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('dialog_input')), 'hello');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('/item/<n> opens that item', (tester) async {
    await tester.pumpWidget(const DemoApp(initialRoute: '/item/42'));
    await tester.pumpAndSettle();
    expect(find.text('Item 42 details'), findsOneWidget);
  });

  testWidgets('the login screen names its layout', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const DemoApp());
    expect(find.text('Landscape layout'), findsOneWidget);
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(find.text('Portrait layout'), findsOneWidget);
  });
}
