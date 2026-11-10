enum ValueKind {
  selector,
  selectorList,
  direction,
  orientation,
  boolean,
  integer,
  number,
  keyChord,
  flowFile,
  screenshotName,
  text,
  url,
  commands,
  condition,
  env,
  point,
}

class KeySpec {
  const KeySpec(this.name, this.kind, {this.required = false, this.example, this.description = ''});
  final String name;
  final ValueKind kind;
  final bool required;
  final String? example;
  final String description;
}

class CommandSpec {
  const CommandSpec(
    this.name, {
    this.description = '',
    this.bare = false,
    this.scalar,
    this.scalarExample,
    this.keys = const [],
    this.selectorForm = false,
  });
  final String name;
  final String description;
  final bool bare;
  final ValueKind? scalar;
  final String? scalarExample;
  final List<KeySpec> keys;
  final bool selectorForm;
}

const List<KeySpec> _selectorKeys = [
  KeySpec('text', ValueKind.text, example: 'Login', description: 'Visible text or label of the element'),
  KeySpec('id', ValueKind.text, example: 'login_button', description: 'Widget key or semantics identifier'),
  KeySpec('index', ValueKind.integer, example: '0', description: 'Which match to use when several match, from 0'),
  KeySpec('enabled', ValueKind.boolean, example: 'true', description: 'Only match enabled (or disabled) elements'),
  KeySpec('childOf', ValueKind.selector, example: 'Settings', description: 'Only match inside this element'),
  KeySpec('type', ValueKind.text, example: 'ElevatedButton', description: 'Widget type of the element'),
];

const List<KeySpec> _tapKeys = [
  ..._selectorKeys,
  KeySpec(
    'point',
    ValueKind.point,
    example: '50%, 50%',
    description: 'Screen point "x, y" or "x%, y%" instead of an element',
  ),
];

const List<KeySpec> _appIdKey = [
  KeySpec('appId', ValueKind.text, example: 'com.example.app', description: 'Maestro app id; accepted and ignored'),
];

/// What the flow language accepts, for editor suggestions and templates.
/// `flow_schema_test.dart` checks it against [FlowParser].
///
/// A [KeySpec] marked `required` is part of the command's minimal map form;
/// where the parser needs one of several keys (`visible` or `notVisible`,
/// `times` or `while`, `direction` or `start`/`end`, `file` or `commands`),
/// the first is marked.
class FlowSchema {
  static const List<CommandSpec> commands = [
    CommandSpec(
      'launchApp',
      description: 'Launches the app',
      bare: true,
      keys: [
        KeySpec('clearState', ValueKind.boolean, example: 'true', description: 'Clear app data before launching'),
        KeySpec('stopApp', ValueKind.boolean, example: 'false', description: 'Stop a running app first (default true)'),
        ..._appIdKey,
      ],
    ),
    CommandSpec('stopApp', description: 'Stops the app', bare: true, keys: _appIdKey),
    CommandSpec('killApp', description: 'Kills the app', bare: true, keys: _appIdKey),
    CommandSpec('clearState', description: 'Clears the app\'s data', bare: true, keys: _appIdKey),
    CommandSpec(
      'tapOn',
      description: 'Taps the element or point',
      scalar: ValueKind.text,
      scalarExample: 'Login',
      selectorForm: true,
      keys: _tapKeys,
    ),
    CommandSpec(
      'doubleTapOn',
      description: 'Double-taps the element or point',
      scalar: ValueKind.text,
      scalarExample: 'Login',
      selectorForm: true,
      keys: _tapKeys,
    ),
    CommandSpec(
      'longPressOn',
      description: 'Long-presses the element or point',
      scalar: ValueKind.text,
      scalarExample: 'Login',
      selectorForm: true,
      keys: _tapKeys,
    ),
    CommandSpec(
      'hover',
      description: 'Moves the pointer over the element',
      scalar: ValueKind.text,
      scalarExample: 'Help',
      selectorForm: true,
      keys: _selectorKeys,
    ),
    CommandSpec(
      'inputText',
      description: 'Types text into the focused field',
      scalar: ValueKind.text,
      scalarExample: 'hello',
      keys: [KeySpec('text', ValueKind.text, required: true, example: 'hello', description: 'Text to type')],
    ),
    CommandSpec(
      'eraseText',
      description: 'Deletes characters from the focused field',
      bare: true,
      scalar: ValueKind.integer,
      scalarExample: '10',
      keys: [
        KeySpec('charactersToErase', ValueKind.integer, example: '10', description: 'How many characters (default 50)'),
      ],
    ),
    CommandSpec(
      'setText',
      description: 'Replaces the text of a field',
      keys: [
        KeySpec('element', ValueKind.selector, required: true, example: 'Email', description: 'The field to change'),
        KeySpec('text', ValueKind.text, required: true, example: 'hello', description: 'The new text'),
      ],
    ),
    CommandSpec(
      'pressKey',
      description: 'Presses a key or key chord',
      scalar: ValueKind.keyChord,
      scalarExample: 'enter',
      keys: [
        KeySpec(
          'key',
          ValueKind.keyChord,
          required: true,
          example: 'enter',
          description: 'Key name or chord, e.g. ctrl+a',
        ),
      ],
    ),
    CommandSpec('back', description: 'Navigates back', bare: true),
    CommandSpec('hideKeyboard', description: 'Hides the keyboard', bare: true),
    CommandSpec(
      'setOrientation',
      description: 'Rotates the device',
      scalar: ValueKind.orientation,
      scalarExample: 'PORTRAIT',
      keys: [
        KeySpec(
          'orientation',
          ValueKind.orientation,
          required: true,
          example: 'PORTRAIT',
          description: 'PORTRAIT, LANDSCAPE_LEFT or LANDSCAPE_RIGHT',
        ),
      ],
    ),
    CommandSpec(
      'openLink',
      description: 'Opens a deep link in the app',
      scalar: ValueKind.url,
      scalarExample: 'demo://app/item/1',
      keys: [
        KeySpec('link', ValueKind.url, required: true, example: 'demo://app/item/1', description: 'Absolute URL'),
        KeySpec('autoVerify', ValueKind.boolean, example: 'true', description: 'Maestro option; accepted and ignored'),
        KeySpec('browser', ValueKind.boolean, example: 'false', description: 'Maestro option; accepted and ignored'),
      ],
    ),
    CommandSpec(
      'assertVisible',
      description: 'Checks that the element is visible',
      scalar: ValueKind.text,
      scalarExample: 'Welcome',
      selectorForm: true,
      keys: _selectorKeys,
    ),
    CommandSpec(
      'assertNotVisible',
      description: 'Checks that the element is not visible',
      scalar: ValueKind.text,
      scalarExample: 'Error',
      selectorForm: true,
      keys: _selectorKeys,
    ),
    CommandSpec(
      'extendedWaitUntil',
      description: 'Waits until an element appears or disappears',
      keys: [
        KeySpec(
          'visible',
          ValueKind.selector,
          required: true,
          example: 'Welcome',
          description: 'Wait for this element to appear (or use notVisible)',
        ),
        KeySpec(
          'notVisible',
          ValueKind.selector,
          example: 'Loading',
          description: 'Wait for this element to disappear',
        ),
        KeySpec('timeout', ValueKind.integer, required: true, example: '5000', description: 'Longest wait in ms'),
      ],
    ),
    CommandSpec(
      'waitForAnimationToEnd',
      description: 'Waits until the screen stops changing',
      bare: true,
      keys: [KeySpec('timeout', ValueKind.integer, example: '5000', description: 'Longest wait in ms (default 5000)')],
    ),
    CommandSpec('scroll', description: 'Scrolls the screen down', bare: true),
    CommandSpec(
      'scrollUntilVisible',
      description: 'Scrolls until the element is visible',
      keys: [
        KeySpec('element', ValueKind.selector, required: true, example: 'Item 20', description: 'The element to find'),
        KeySpec('direction', ValueKind.direction, example: 'DOWN', description: 'Scroll direction (default DOWN)'),
        KeySpec('timeout', ValueKind.integer, example: '20000', description: 'Longest search in ms (default 20000)'),
        KeySpec('speed', ValueKind.integer, example: '40', description: 'Maestro speed 0-100; accepted and ignored'),
        KeySpec(
          'visibilityPercentage',
          ValueKind.integer,
          example: '100',
          description: 'How much of the element must show, 0-100',
        ),
        KeySpec('centerElement', ValueKind.boolean, example: 'true', description: 'Scroll the element to the middle'),
        KeySpec('scrollable', ValueKind.selector, example: '{id: item_list}', description: 'The list to scroll'),
      ],
    ),
    CommandSpec(
      'swipe',
      description: 'Swipes in a direction or between two points',
      keys: [
        KeySpec(
          'direction',
          ValueKind.direction,
          required: true,
          example: 'LEFT',
          description: 'UP, DOWN, LEFT or RIGHT (or use start and end)',
        ),
        KeySpec('start', ValueKind.point, example: '90%, 50%', description: 'Start point, with end'),
        KeySpec('end', ValueKind.point, example: '10%, 50%', description: 'End point, with start'),
        KeySpec('from', ValueKind.selector, example: 'Card', description: 'Swipe on this element (with direction)'),
        KeySpec('duration', ValueKind.integer, example: '400', description: 'Swipe time in ms (default 400)'),
      ],
    ),
    CommandSpec(
      'takeScreenshot',
      description: 'Saves a screenshot to the run report',
      scalar: ValueKind.text,
      scalarExample: 'home',
      keys: [KeySpec('path', ValueKind.text, required: true, example: 'home', description: 'Screenshot file name')],
    ),
    CommandSpec(
      'assertScreenshot',
      description: 'Compares the screen with a baseline image',
      scalar: ValueKind.screenshotName,
      scalarExample: 'home',
      keys: [
        KeySpec('name', ValueKind.screenshotName, required: true, example: 'home', description: 'Baseline name'),
        KeySpec(
          'threshold',
          ValueKind.number,
          example: '0.5',
          description: 'Allowed difference in percent (default 0.1)',
        ),
        KeySpec(
          'ignore',
          ValueKind.selectorList,
          example: '[Clock]',
          description: 'Elements to leave out of the comparison',
        ),
      ],
    ),
    CommandSpec(
      'runFlow',
      description: 'Runs another flow file or inline commands',
      scalar: ValueKind.flowFile,
      scalarExample: 'login.yaml',
      keys: [
        KeySpec(
          'file',
          ValueKind.flowFile,
          required: true,
          example: 'login.yaml',
          description: 'Flow file relative to this one (or use commands)',
        ),
        KeySpec('commands', ValueKind.commands, example: '- back', description: 'Commands to run instead of a file'),
        KeySpec('env', ValueKind.env, example: '{USER: alice}', description: 'Variables for the subflow'),
        KeySpec('when', ValueKind.condition, example: '{platform: Android}', description: 'Run only if this holds'),
      ],
    ),
    CommandSpec(
      'repeat',
      description: 'Repeats commands a number of times or while a condition holds',
      keys: [
        KeySpec('times', ValueKind.integer, required: true, example: '3', description: 'How many times (or use while)'),
        KeySpec('while', ValueKind.condition, example: '{visible: Load more}', description: 'Repeat while this holds'),
        KeySpec('commands', ValueKind.commands, required: true, example: '- scroll', description: 'Commands to repeat'),
      ],
    ),
  ];

  static final Map<String, CommandSpec> _byName = {for (final c in commands) c.name: c};

  static CommandSpec? command(String name) => _byName[name];

  static const List<String> selectorKeys = ['text', 'id', 'index', 'enabled', 'childOf', 'type'];
  static const List<String> conditionKeys = ['visible', 'notVisible', 'platform', 'true'];
  static const List<String> headerKeys = ['appId', 'name', 'tags', 'env', 'onFlowStart', 'onFlowComplete'];
  static const List<KeySpec> headerKeySpecs = [
    KeySpec('appId', ValueKind.text, example: 'com.example.app', description: 'Maestro app id; accepted and ignored'),
    KeySpec('name', ValueKind.text, example: 'Login', description: 'Name shown in reports'),
    KeySpec('tags', ValueKind.text, example: '[smoke]', description: 'Tags to select flows by'),
    KeySpec('env', ValueKind.env, example: 'USER: demo', description: 'Variables for this flow'),
    KeySpec('onFlowStart', ValueKind.commands, example: '- launchApp', description: 'Commands to run before the flow'),
    KeySpec(
      'onFlowComplete',
      ValueKind.commands,
      example: '- back',
      description: 'Commands to run after the flow, even when it fails',
    ),
  ];

  static const List<KeySpec> selectorKeySpecs = _selectorKeys;

  static const List<KeySpec> conditionKeySpecs = [
    KeySpec('visible', ValueKind.selector, example: 'Welcome', description: 'Holds while this element is visible'),
    KeySpec(
      'notVisible',
      ValueKind.selector,
      example: 'Loading',
      description: 'Holds while this element is not visible',
    ),
    KeySpec('platform', ValueKind.text, example: 'iOS', description: 'Holds on this platform'),
    // A plain variable reference: the parser rejects JavaScript expressions.
    KeySpec('true', ValueKind.text, example: r'${IS_DEMO}', description: 'Holds when the variable is true'),
  ];

  static final Map<String, KeySpec> _headerByName = {for (final k in headerKeySpecs) k.name: k};

  static KeySpec? headerKey(String name) => _headerByName[name];

  static const List<String> directions = ['UP', 'DOWN', 'LEFT', 'RIGHT'];
  static const List<String> orientations = ['PORTRAIT', 'LANDSCAPE_LEFT', 'LANDSCAPE_RIGHT'];
  static const List<String> platforms = ['iOS', 'Android', 'macOS', 'Windows', 'Linux'];
  static const List<String> optionKeys = ['label', 'optional'];
}
