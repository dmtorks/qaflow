# qaflow_agent

The in-app half of QAFlow. It registers
`ext.qa.*` service extensions on the Dart VM service so the `qaflow` driver can find
widgets, tap, type, scroll and take screenshots in a running debug or profile build.

Add it as a normal dependency, not a dev dependency: `lib/main_qa.dart` lives in `lib/`
and imports it. It still stays out of release builds, for two reasons. The driver launches
the separate `lib/main_qa.dart` entrypoint, and your `lib/main.dart`, which release builds
compile, never imports the agent. And `QaAgent.install()` throws when `kReleaseMode` is
true, so even a release build of `main_qa.dart` refuses to register anything.

## Install

```sh
flutter pub add qaflow_agent
```

Create `lib/main_qa.dart` next to your normal `lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

void main() {
  QaAgent.install();
  runApp(QaAgent.wrap(const MyApp()));
}
```

Pass `onReset` to `QaAgent.install` to clear your app's persisted state when a flow
asks for a clean start. Then run flows with the `qa` CLI from the `qaflow` package.

See [example/lib/main.dart](example/lib/main.dart). In your app it is `lib/main_qa.dart`; the example
names it `main.dart` so pub.dev shows it.

## More

QAFlow is three packages: this one goes in the app under test,
[qaflow](https://pub.dev/packages/qaflow) runs the flows and provides the `qa` command, and
[qaflow_protocol](https://pub.dev/packages/qaflow_protocol) holds the messages they share.

Read the [QAFlow docs](https://github.com/dmtorks/qaflow) for the command reference, CI setup,
remote hosts and troubleshooting, and report issues on its
[issue tracker](https://github.com/dmtorks/qaflow/issues).
