import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

/// Pumps frames until [future] completes. Agent code awaits endOfFrame and
/// Future.delayed, which only advance under the test binding when frames are pumped.
Future<T> pumpUntil<T>(
  WidgetTester tester,
  Future<T> future, {
  Duration step = const Duration(milliseconds: 16),
  int maxFrames = 600,
}) async {
  var done = false;
  late T value;
  Object? error;
  StackTrace? stack;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e, StackTrace s) {
      error = e;
      stack = s;
      done = true;
    },
  );
  for (var i = 0; i < maxFrames && !done; i++) {
    await tester.pump(step);
  }
  if (!done) fail('future did not complete within $maxFrames frames');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}

/// A MaterialApp wrapped the way main_qa.dart wraps the real app, with
/// synthetic device pointer events allowed to reach the framework.
Future<void> pumpApp(WidgetTester tester, Widget home, {GlobalKey<NavigatorState>? navigatorKey}) async {
  tester.binding.shouldPropagateDevicePointerEvents = true;
  await tester.pumpWidget(QaAgent.wrap(MaterialApp(navigatorKey: navigatorKey, home: home)));
}

/// Call once at the top of a test file's `main()`, before any `testWidgets`
/// calls, so [pumpApp]'s pointer-event flag is already at its post-test
/// value when each test starts. Without this, the binding's end-of-test
/// invariant check fails on whichever test first flips the flag from its
/// default of false.
void allowDevicePointerPropagation() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized().shouldPropagateDevicePointerEvents = true);
}

/// Delivers an app-lifecycle message the same way the engine does, through
/// `SystemChannels.lifecycle`, so `SchedulerBinding.instance.lifecycleState`
/// and `framesEnabled` change exactly as they would on a real device.
Future<void> setLifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.lifecycle.name,
      SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
      (_) {},
    );
