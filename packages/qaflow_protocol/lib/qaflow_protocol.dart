/// Wire types shared by the QAFlow in-app agent (`qaflow_agent`) and its
/// driver (`qaflow`).
///
/// The driver calls the agent's `ext.qa.*` VM service extensions, named by
/// [QaMethod], with [Selector]s that pick a widget. The agent answers with a
/// [QaResponse] carrying a result, often [QaNode]s, or a [QaErrorCode].
library;

export 'src/key_chord.dart';
export 'src/method.dart';
export 'src/node.dart';
export 'src/response.dart';
export 'src/screenshot_transfer.dart';
export 'src/selector.dart';
export 'src/version.dart';
