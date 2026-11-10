# qaflow_agent example

A counter app set up for QAFlow. It has two entrypoints, which is how your own app should look:

```
lib/
  main.dart      the app. Release builds compile this, and it never imports the agent.
  main_qa.dart   the same app with the agent installed. QAFlow launches this one.
```

## lib/main.dart

The app itself. The widgets that flows act on have a `ValueKey<String>`, so flows can find them by `id`
whatever their text says:

```dart
void main() => runApp(const CounterApp());

// ...
body: Center(child: Text('Count: $_count', key: const ValueKey('count'))),
floatingActionButton: FloatingActionButton(
  key: const ValueKey('increment'),
  onPressed: _increment,
  child: const Icon(Icons.add),
),
```

## lib/main_qa.dart

```dart
import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

import 'main.dart';

void main() {
  QaAgent.install(onReset: () => CounterStore.count = 0);
  runApp(QaAgent.wrap(const CounterApp()));
}
```

- `install` registers the agent. `onReset` wipes the app's saved state when a flow uses `clearState`.
- `wrap` lets flows take screenshots.

## A flow for it

```yaml
# .qa/flows/counter.yaml
name: The counter goes up
---
- launchApp: {clearState: true}
- assertVisible: "Count: 0"
- tapOn: {id: increment}
- tapOn: {id: increment}
- assertVisible: "Count: 2"
- takeScreenshot: counter
```

```yaml
# .qa/project.yaml
app:
  source: .
```

Run it from the app's folder with the `qa` command from the [qaflow](https://pub.dev/packages/qaflow) package:

```sh
dart pub global activate qaflow
qa test
```
