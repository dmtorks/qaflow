# qaflow_agent

The in-app half of QAFlow. It registers
`ext.qa.*` service extensions on the Dart VM service so the `qaflow` driver can find
widgets, tap, type, scroll and take screenshots in a running debug or profile build.

QAFlow is three packages: this one goes in the app under test,
[qaflow](https://pub.dev/packages/qaflow) runs the flows and provides the `qa` command, and
[qaflow_protocol](https://pub.dev/packages/qaflow_protocol) holds the messages they share.

## Requirements

- Flutter 3.44 or later.
- Android, iOS, macOS, Linux or Windows. Web is not supported.
- A debug or profile build. Release builds have no VM service, so they can't be driven.
  On the iOS simulator Flutter only allows debug.

## Install

```sh
flutter pub add qaflow_agent
```

Add it as a normal dependency, not a dev dependency, because the QA entrypoint below lives in `lib/`.

## Add a separate QA entrypoint

Keep your `lib/main.dart` as it is, and create a second entrypoint, `lib/main_qa.dart`, beside it.
Only `main_qa.dart` imports the agent:

```
lib/
  main.dart      your app, as it is today. Release builds compile this.
  main_qa.dart   the same app with the agent installed. QAFlow launches this.
```

```dart
// lib/main_qa.dart
import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

import 'main.dart' show MyApp;

void main() {
  QaAgent.install();
  runApp(QaAgent.wrap(const MyApp()));
}
```

- `QaAgent.install()` registers the service extensions. Call it before `runApp`.
- `QaAgent.wrap()` puts a `RepaintBoundary` around the app, which is what screenshots capture.

The QAFlow driver launches the app with `flutter run -t lib/main_qa.dart`. You can do the same by hand to
check that it starts.

Why a separate file? Your release build compiles `lib/main.dart`, which never imports the agent, so none of
it ships. As a second guard, `QaAgent.install()` throws a `StateError` when `kReleaseMode` is true, so even a
release build of `main_qa.dart` refuses to start the agent.

## Apps with setup code

If your `main.dart` does more than `runApp` (Firebase, dependency injection, flavors, error reporting), move that
work into a function both entrypoints call. Then the QA build runs the same setup as the real app:

```dart
// lib/bootstrap.dart
Future<Widget> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await setUpDependencies();
  return const MyApp();
}

// lib/main.dart
Future<void> main() async => runApp(await bootstrap());

// lib/main_qa.dart
Future<void> main() async {
  QaAgent.install(onReset: resetAppState);
  runApp(QaAgent.wrap(await bootstrap()));
}
```

`main_qa.dart` is also the place for test-only switches, such as pointing at a staging server or skipping a
native permission prompt that the agent can't tap.

## Make widgets findable

Flows pick widgets with selectors. The agent matches them against the widget tree like this:

| In the flow | Matches in your app |
|---|---|
| `tapOn: Log in` or `{text: Log in}` | A widget whose visible text is "Log in" (`Text`, `RichText`, a text field's value). Also a full regular expression, such as `Item \d+` |
| `{id: login}` | A `ValueKey<String>('login')` **or** a `Semantics(identifier: 'login')` |
| `{type: Checkbox}` | The widget's class name |

Text is the easiest place to start, but it breaks when wording, translations or counts change. For anything you
tap or check often, give it an id:

```dart
ElevatedButton(
  key: const ValueKey('login'),
  onPressed: _submit,
  child: const Text('Log in'),
)
```

```yaml
- tapOn: {id: login}
```

Only `ValueKey<String>` counts. `ValueKey<int>`, `ObjectKey` and `GlobalKey` are ignored. When you can't put a key
on the widget itself (for example inside a package widget), wrap it in `Semantics(identifier: 'login', child: ...)`,
which also helps accessibility tools.

When several widgets match, narrow the selector with `index`, `enabled` or `childOf`. The full list is in the
[selector reference](https://github.com/dmtorks/qaflow/blob/main/docs/commands.md).

## Reset state between flows

A flow can start with `clearState` (or `launchApp: {clearState: true}`) to begin from a fresh install. The agent
can't know where your app keeps its data, so you pass a function that wipes it:

```dart
Future<void> resetAppState() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await const FlutterSecureStorage().deleteAll();
  await AppDatabase.instance.deleteEverything();
}

void main() {
  QaAgent.install(onReset: resetAppState);
  runApp(QaAgent.wrap(const MyApp()));
}
```

After `onReset` finishes, the runner restarts the app. Without `onReset`, `clearState` fails with
"the app registered no reset hook; pass onReset to QaAgent.install".

## Run a first flow

Install the CLI from the [qaflow](https://pub.dev/packages/qaflow) package, then add `.qa/project.yaml` and a flow
in `.qa/flows/`:

```sh
dart pub global activate qaflow
```

```yaml
# .qa/flows/login.yaml
name: Log in
---
- launchApp
- tapOn: {id: login}
- assertVisible: Welcome
```

```sh
qa test
```

The [qaflow README](https://pub.dev/packages/qaflow) covers `project.yaml`, devices, reports, and
subflows, which let several flows share steps such as logging in.

## Troubleshooting

| You see | Cause | Fix |
|---|---|---|
| `no isolate exposes ext.qa.ping`, or Studio says the build may not include the QA agent | The app wasn't started from `lib/main_qa.dart`, or it doesn't call `QaAgent.install()` | Launch with `-t lib/main_qa.dart` and call `install()` before `runApp` |
| `screenshots need QaAgent.wrap() around the app in main_qa.dart` | The app isn't wrapped | `runApp(QaAgent.wrap(...))` |
| `qaflow_agent must not be compiled into release builds` | A release build of `main_qa.dart` | Use debug or profile |
| `the app registered no reset hook` | A flow uses `clearState` | Pass `onReset:` to `QaAgent.install` |
| `agent protocol vX does not match driver protocol vY` | The app's `qaflow_agent` and the `qa` CLI are different versions | Use the same version for both |
| `ambiguous`: several widgets match | A selector matches more than one widget | Use an `id`, or add `index` or `childOf` |

More in the [troubleshooting guide](https://github.com/dmtorks/qaflow/blob/main/docs/troubleshooting.md).

## More

- A complete example: [example/](example/README.md).
- The [QAFlow docs](https://github.com/dmtorks/qaflow) cover the command reference, CI setup and remote hosts.
- Report problems on the [issue tracker](https://github.com/dmtorks/qaflow/issues).
