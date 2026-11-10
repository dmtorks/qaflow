# qaflow_protocol

Pure Dart wire types shared by the QAFlow
in-app agent and its driver: `Selector`, `QaMethod`, `QaResponse`, `QaErrorCode`,
`KeyChord` and the screenshot transfer helpers. It has no Flutter dependency, so it
runs in the CLI, in tools and in CI.

You usually get it transitively through `qaflow_agent` or `qaflow`. Depend on it
directly only when you write your own driver or tooling.

## Install

```sh
dart pub add qaflow_protocol
```

## Use

```dart
import 'package:qaflow_protocol/qaflow_protocol.dart';

final json = const Selector(text: 'Sign in', enabled: true).toJson();
final response = QaResponse.fromJson({'ok': true, 'v': protocolVersion, 'result': {}});
```

See [example/qaflow_protocol_example.dart](example/qaflow_protocol_example.dart).

## More

You don't need to add this package yourself: it comes with
[qaflow_agent](https://pub.dev/packages/qaflow_agent) and [qaflow](https://pub.dev/packages/qaflow).
Read the [QAFlow docs](https://github.com/dmtorks/qaflow) for how to use QAFlow, and report issues on its
[issue tracker](https://github.com/dmtorks/qaflow/issues).
