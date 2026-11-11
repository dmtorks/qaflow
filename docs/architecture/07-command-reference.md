# 7. Command reference

Every command the toolkit understands, in one place:

- [flow commands](#71-flow-commands), with every form, option, default and an example;
- [selectors](#72-selectors);
- [key names](#73-key-names-for-presskey);
- [conditions and variables](#74-conditions-and-variables);
- [the flow file header](#75-the-flow-file-header);
- the [`qa` command line tool](#76-the-qa-command-line-tool);
- [QAFlow Studio's commands and shortcuts](#77-qaflow-studio-commands-and-shortcuts).

[Chapter 3](03-flows-and-reports.md) explains how flows run; this chapter is for looking things up. The sources of truth are `FlowParser` ([`parser.dart`](../../packages/qaflow/lib/src/flow/parser.dart)), which decides what is accepted, `CommandExecutor` and `FlowRunner`, which decide what it does, and `FlowSchema` ([`flow_schema.dart`](../../packages/qaflow/lib/src/flow/flow_schema.dart)), which QAFlow Studio's editor reads for suggestions and hover docs and which tests keep equal to the parser.

## 7.1 Flow commands

**Rules that apply to every command:**

- **Forms.** A command is a bare word (`- scroll`), a word with a scalar value (`- tapOn: Login`), or a word with a map of options (`- tapOn: {id: login}`, or the same map in block style). A list item holds exactly one command. Each command below lists the forms it accepts; any other form is a parse error (for example "scroll needs a map of options" for `- scroll: 3`).
- **Common options.** Every map form also accepts:
  - **`label:`** replaces the step's title in reports and the live view. Labels are never variable-substituted.
  - **`optional: true`** turns a failure into a warning, and the flow carries on. It doesn't soften infrastructure errors, where the app or its connection is gone.
- **Retrying.** Steps that look for an element retry for up to **10 seconds**, every 100 ms, letting the app settle before each try. That's why most flows need no waits. The retried errors are `not_found`, `ambiguous`, `not_ready`, `off_screen` and `obscured`.
- **Unknown input is an error.** Unknown commands, options and Maestro-only commands fail when the file is parsed, before anything runs, with `file:line:column: message`. An unknown option reads "`<command>` does not accept "`<option>`"".
- **Values.** Strings may be written as numbers or booleans (`inputText: 42` types "42"). Whole-number options reject decimals. Options that take milliseconds reject negative numbers.

The 27 commands, in the parser's order: `launchApp`, `stopApp`, `killApp`, `clearState`, `tapOn`, `doubleTapOn`, `longPressOn`, `hover`, `inputText`, `eraseText`, `setText`, `pressKey`, `back`, `hideKeyboard`, `setOrientation`, `openLink`, `assertVisible`, `assertNotVisible`, `extendedWaitUntil`, `waitForAnimationToEnd`, `scroll`, `scrollUntilVisible`, `swipe`, `takeScreenshot`, `assertScreenshot`, `runFlow`, `repeat`.

### App lifecycle

#### `launchApp`

Makes sure the app is running and fresh.

| Form | Meaning |
|---|---|
| `- launchApp` | Defaults below |
| `- launchApp: com.example.app` | A scalar is Maestro's app id; ignored |
| `- launchApp: {clearState: true}` | Map with options |

| Option | Default | Meaning |
|---|---|---|
| `clearState` | `false` | Run the app's reset hook (`QaAgent.install(onReset: …)`) and restart |
| `stopApp` | `true` | `false`: leave a running app alone instead of restarting it |
| `appId` | none | Accepted for Maestro compatibility; ignored |

```yaml
- launchApp
- launchApp: {clearState: true}
```

The runner already restarts the app before every flow. So `launchApp` at the top of a flow normally does nothing, and the step's note says "app already fresh". Later in a flow it restarts the app: a hot restart in debug, a relaunch in profile or for a prebuilt app. With `stopApp: false` it notes "app already running" instead. If the app was stopped, it starts it.

#### `stopApp` / `killApp`

Stops the app. The two names are the same command; the step keeps the name you wrote. Every later step except `launchApp`, `clearState`, `runFlow` and `repeat` fails with `not_ready`, "the app is not running; add launchApp after stopApp".

| Form | Meaning |
|---|---|
| `- stopApp` | Stop |
| `- stopApp: com.example.app` | A scalar app id is ignored |
| `- stopApp: {appId: …, label: …, optional: …}` | Map; `appId` ignored |

#### `clearState`

Runs the app's reset hook, then restarts the app. Same forms as `stopApp`. **Fails with `unsupported`** when the app registered no hook ("the app registered no reset hook; pass onReset to QaAgent.install").

```yaml
- clearState
```

### Tapping and pointing

#### `tapOn`, `doubleTapOn`, `longPressOn`

Taps, double-taps or long-presses an element, or a point in the window.

| Form | Meaning |
|---|---|
| `tapOn: Log in` | The element whose text is "Log in" (see [selectors](#72-selectors)) |
| `tapOn: {id: login}` | Any [selector](#72-selectors) |
| `tapOn: {point: "120, 340"}` | A point in logical pixels from the window's top-left |
| `tapOn: {point: "50%, 90%"}` | A point as a fraction of the window; each axis can be `%` or pixels |

```yaml
- tapOn: {id: login}
- doubleTapOn: {text: "Item 3"}
- longPressOn: {point: "50%, 50%"}
```

- **Tapping by selector** checks that the element is visible, not covered and enabled, then taps the centre of its visible part. It fails with `obscured` if something covers it, and with `not_ready` if it's disabled (both retried until the timeout).
- **Tapping a point** settles first, then taps exactly there, with no checks and no retry. `point` cannot be combined with selector fields.
- **Double taps** are two taps 100 ms apart, inside Flutter's double-tap window.
- **Touch or mouse.** On iOS and Android the agent sends touch events; on desktop, mouse events.
- **Rejected Maestro options:** `repeat`, `delay`, `retryTapIfNoChange`, `waitToSettleTimeoutMs` ("tapOn option X is not supported").

#### `hover`

Moves the mouse over an element. That triggers hover effects, tooltips and `MouseRegion` callbacks. Mouse only: on iOS and Android it fails with `unsupported` ("hover needs a mouse; this app runs on a touch platform").

| Form | Meaning |
|---|---|
| `hover: Help` | By text |
| `hover: {id: open_dialog}` | Any selector (no `point`) |

```yaml
- hover: {id: open_dialog}
- assertVisible: Opens a dialog   # the tooltip
```

### Typing and keys

#### `inputText`

Types text into the **focused** field at the cursor, through the same path as a keyboard. Input formatters and `onChanged` run as normal. Tap a field first to focus it.

| Form | Meaning |
|---|---|
| `inputText: hello` | Type "hello" |
| `inputText: {text: hello}` | The same, as a map |

```yaml
- tapOn: {id: email}
- inputText: test@example.com
- inputText: ${PASSWORD}
```

No field focused: `not_ready`, "no text field has focus; pass a selector or tap a field first" (retried until the timeout, so a field that gains focus late still works). A read-only or disabled field is refused with `not_ready`.

#### `eraseText`

Deletes characters before the cursor in the focused field.

| Form | Meaning |
|---|---|
| `- eraseText` | 50 characters |
| `- eraseText: 3` | 3 characters (at least 1) |
| `- eraseText: {charactersToErase: 3}` | 3 characters |

#### `setText`

Replaces a field's whole contents without tapping it first. Map form only.

| Option | Default | Meaning |
|---|---|---|
| `element` | required | The field: a [selector](#72-selectors) |
| `text` | required | The new contents |

```yaml
- setText:
    element: {id: search}
    text: flutter
```

#### `pressKey`

Presses a key or key combination ([key names](#73-key-names-for-presskey)).

| Form | Meaning |
|---|---|
| `pressKey: enter` | A key or chord |
| `pressKey: {key: mod+s}` | The same, as a map |

```yaml
- pressKey: enter
- pressKey: mod+s          # ⌘S on macOS, Ctrl+S elsewhere
- pressKey: shift+tab
```

- **Enter submits.** A bare `enter` that the app left unhandled also submits the focused text field: single-line fields fire their action, multi-line fields get a newline. If a focused widget handled Enter itself (an autocomplete accepting a suggestion), the field is not submitted as well.
- **Checked when the file is parsed:** an empty part (`ctrl+`) or an unknown modifier (`hyper+a`).
- **Checked when the step runs:** an unknown key name (`entr`) fails with `bad_request`, `unknown key "entr"`. A chord containing `${…}` is checked only then.
- **`pressKey: back`** (any case) is an alias of [`back`](#back): it runs the Android system back, and the step keeps its `pressKey back` title.
- Not retried: the key either reaches the focus tree or it does not.

### Checking

#### `assertVisible` / `assertNotVisible`

Wait up to the step timeout (10 s) for an element to be visible, or to be gone.

| Form | Meaning |
|---|---|
| `assertVisible: Welcome` | By text |
| `assertVisible: {id: login, enabled: true}` | Any selector |

```yaml
- assertVisible: Welcome
- assertVisible: {id: login, enabled: true}
- assertNotVisible: {text: "Loading"}
```

"Visible" means at least part of the element is inside the window and inside any scroll view that contains it. When it fails, the step saves a screenshot and an element dump (`elements-<step>.json`) listing what was on screen.

#### `extendedWaitUntil`

Like an assertion, with its own timeout. Use it for slow work: a network call, an import. Map form only; exactly one of `visible` and `notVisible`.

| Option | Default | Meaning |
|---|---|---|
| `visible` | one of these two | A selector to wait for |
| `notVisible` | one of these two | A selector to wait to disappear |
| `timeout` | required | Milliseconds |

```yaml
- extendedWaitUntil:
    visible: {text: "Import complete"}
    timeout: 60000
```

#### `waitForAnimationToEnd`

Waits until the app has settled: no frames scheduled, or the element tree unchanged for three frames and at least 500 ms.

| Form | Meaning |
|---|---|
| `- waitForAnimationToEnd` | Up to 5000 ms |
| `- waitForAnimationToEnd: {timeout: 10000}` | Up to 10000 ms |

Running out of time is not a failure; the flow carries on.

### Scrolling and dragging

#### `scroll`

Scrolls the main list down by 70% of its visible height, with the mouse wheel at the list's centre. "Main" means the visible scroll view with the largest visible area. Bare, or a map with only `label`/`optional`. Fails with `not_found`, "no visible scrollable on screen", when there is none.

```yaml
- scroll
```

#### `scrollUntilVisible`

Scrolls until an element is visible enough. This is the way to reach list rows that aren't built yet: Flutter only creates rows near the screen. Map form only.

| Option | Default | Meaning |
|---|---|---|
| `element` | required | The [selector](#72-selectors) to reveal |
| `direction` | `DOWN` | `UP`, `DOWN`, `LEFT` or `RIGHT` (any case) |
| `timeout` | `20000` | ms before failing |
| `visibilityPercentage` | `100` | How much of the element must show, 0 to 100 |
| `centerElement` | `false` | Finish with the element centred in the list |
| `scrollable` | the main list | A selector naming which scroll view to scroll |
| `speed` | none | Maestro's 0 to 100; checked, then ignored |

```yaml
- scrollUntilVisible:
    element: Item 150
    direction: DOWN
    centerElement: true
```

Each scroll moves half the list's visible extent. Fails with "… not visible after scrolling down for 20000 ms".

#### `swipe`

Drags: for sliders, drag-to-dismiss, reorderable lists and other draggable widgets. **On desktop a mouse drag does not scroll a list**; use `scroll` or `scrollUntilVisible` for that. On iOS and Android the drag is a touch, so it does scroll a list, with fling. Map form only; either `direction` or both `start` and `end`.

| Option | Default | Meaning |
|---|---|---|
| `direction` | one of these | `LEFT` (90%→10% across), `RIGHT` (10%→90%), `UP` (50%→10% down the middle), `DOWN` (20%→90%) |
| `from` | the window | With `direction` only: do the preset within this element's visible area |
| `start`, `end` | one of these | Two points, each `"x, y"` in pixels or `%` |
| `duration` | `400` | ms |

```yaml
- swipe: {direction: LEFT}
- swipe: {direction: LEFT, from: {id: card}}
- swipe: {start: "80%, 50%", end: "20%, 50%", duration: 300}
```

### Device commands

For iOS simulators and Android emulators. All four settle afterwards and accept `label` and `optional` in a map form.

#### `back`

Android system back: the same path the hardware back button takes (it pops a route or closes a dialog). Fails with `unsupported` ("back is only available on Android") on every other platform, so gate it in a flow shared across platforms:

```yaml
- runFlow:
    when: {platform: android}
    commands:
      - back
```

Forms: `- back`, `- back: {label: …, optional: …}`, or `- pressKey: back`. `back: <anything else>` is "back takes no value".

#### `hideKeyboard`

Drops focus and hides the soft keyboard. Works on every platform (on desktop it only drops focus). Same forms as `back`.

```yaml
- tapOn: {id: username}
- hideKeyboard
- tapOn: Sign in       # a button the keyboard covered
```

#### `setOrientation`

`PORTRAIT`, `LANDSCAPE_LEFT` or `LANDSCAPE_RIGHT`, in any case; `LANDSCAPE` means `LANDSCAPE_LEFT`. `unsupported` on desktop ("setOrientation needs an iOS simulator or Android emulator, not macOS").

| Form | Meaning |
|---|---|
| `setOrientation: LANDSCAPE` | The orientation |
| `setOrientation: {orientation: PORTRAIT}` | The same, as a map |

- **Android** rotates the emulator through `adb` and waits up to 10 s for the app's view to change aspect. A switch straight between the two landscapes is not waited for. An app locked to one orientation costs the full 10 s.
- **iOS** sets the app's preferred orientation through the agent, because `simctl` has no rotate command.
- **After the flow** the runner puts the device back in portrait if any step of that attempt ran `setOrientation`, even if the flow failed. A failed restore is logged as `[qa] could not restore portrait orientation: …` and does not fail the flow.

```yaml
- setOrientation: LANDSCAPE
- assertVisible: Landscape layout
```

#### `openLink`

Opens a URL on the device: `am start -W -a android.intent.action.VIEW -d <url>` on Android, `simctl openurl` on iOS. `unsupported` on desktop. The link must be an absolute URL with a scheme ("openLink needs an absolute URL with a scheme, e.g. demo://app/item/1"), unless it contains a variable.

| Form | Meaning |
|---|---|
| `openLink: demo://app/item/42` | The link |
| `openLink: {link: …, autoVerify: true, browser: false}` | Maestro's options are accepted and ignored |

A link the OS hands to another app leaves this one in the background; the next step that needs a frame then reports `not_ready`. **On iOS a custom-scheme link first shows an "Open in …?" system alert** that the agent cannot tap, so a flow asserting on the result works only on Android today.

### Screenshots

#### `takeScreenshot`

Saves a PNG into the run folder, under `flows/<flow>/screenshots/` (or `screenshots/attempt-<n>/` on a retry).

| Form | Meaning |
|---|---|
| `takeScreenshot: login-filled` | The name |
| `takeScreenshot: {path: dialogs/confirm}` | The same, as a map; subfolders allowed |

A trailing `.png` is dropped and characters outside `A-Z a-z 0-9 . _ / -` become `_`. A name that would escape the screenshots folder (`../`) fails with `bad_request`.

#### `assertScreenshot`

Captures the screen and compares it with a baseline PNG. Chapter 3.4 explains the whole mechanism.

| Form | Meaning |
|---|---|
| `assertScreenshot: dialog-open` | Just the name; defaults for the rest |
| `assertScreenshot: {name: list, threshold: 0.5, ignore: [...]}` | Map |

```yaml
- assertScreenshot: dialog-open
- assertScreenshot:
    name: list
    threshold: 0.5                         # max % of differing pixels; default 0.1
    ignore:                                # areas blanked in both images first
      - text: Item 0
      - id: clock
```

| Option | Default | Meaning |
|---|---|---|
| `name` | required | Letters, digits, `-`, `_` and `.` (not `.` or `..`). Names the baseline file. A literal bad name is a parse error that `qa validate` reports; a name that becomes bad after variable substitution fails the step with `bad_request` |
| `threshold` | `0.1` | 0 to 100, the largest percentage of differing pixels that still passes |
| `ignore` | none | A list of selectors. Every visible match's area is blanked in both images; a selector that matches nothing is fine. There are no fixed rectangle regions: name the widget instead |
| `label`, `optional` | | As on every command |

Any other key, including Maestro's own options for this command, is a parse error.

- **Capture.** Settles like `takeScreenshot`, and retries `not_ready` (a window that is not rendering yet) until the step timeout.
- **Baseline.** `<app root>/.qa/baselines/<device key>/<flow slug>/<name>.png`.
  - The **device key** is the platform name and host OS version (`major.minor`) on desktop (`macos-27.0`; bare `macos` when the version cannot be read, and `flutter-tester` has none) and `<platform>-<device name>-<OS version>` on a simulator or emulator (`ios-iPhone_17_Pro-iOS_26.5`). Characters outside `A-Z a-z 0-9 .` turn into `_`. `-<suffix>` is added when `QA_BASELINE_KEY_SUFFIX` is set.
  - The **flow slug** is the top-level flow file's path under `.qa/` without the extension, slugified (`flows-screenshot`), or the file's basename outside `.qa/`. Renaming or moving a flow file moves its baselines.
- **Mode** (`qa test --baselines`, else `flows.baselines`, else `record`):

  | Mode | No baseline | Baseline exists |
  |---|---|---|
  | `record` | Write it; step warns `baseline recorded` | Compare |
  | `strict` | Fail: `no baseline for "<name>" on <device key> (run with --baselines record or update)` | Compare |
  | `update` | Write it; passes `baseline updated` | Overwrite it; passes `baseline updated` |

- **Comparison.** A pixel differs when a channel differs by more than 8 of 255. Fails with `screenshot_mismatch`: `<p>% of pixels differ (threshold <t>%)`, or `size <w>×<h> differs from baseline <w>×<h>`.
- **Files** in the step's screenshots folder: `<name>.actual.png` always; `<name>.baseline.png` on a comparison; `<name>.diff.png` on a failed one (actual dimmed, differences red, ignored areas dark blue).
- **Accepting.** In QAFlow Studio, a failed comparison in a run's detail has **Accept as baseline**, which copies the actual image over the baseline after a confirmation. From the command line, rerun with `--baselines update`, or copy `<name>.actual.png` over the baseline file yourself.
- **No project.** With `--binary` and no project file, or on a QA host with no local project file: `bad_request: assertScreenshot needs a project (pass --config or --project) to know where baselines live`.

### Composition

#### `runFlow`

Runs another flow file (a subflow), or a list of commands inline.

| Form | Meaning |
|---|---|
| `runFlow: ../subflows/login.yaml` | A file, relative to the current flow |
| `runFlow: {file: …, env: …, when: …}` | The same, with options |
| `runFlow: {commands: [...], env: …, when: …}` | An inline command list instead of a file |

| Option | Meaning |
|---|---|
| `file` | The subflow file. Exactly one of `file` and `commands` |
| `commands` | An inline command list |
| `env` | Variables for the subflow; these win over everything else. Values are substituted in the caller's scope |
| `when` | Run only if a [condition](#74-conditions-and-variables) holds; otherwise the step passes with the note "condition not met" |

```yaml
- runFlow:
    file: ../subflows/login.yaml
    env: {PASSWORD: wrong}
- runFlow:
    when: {visible: "Accept cookies"}
    commands:
      - tapOn: Accept
```

- **Checked up front.** Subflow files are checked when the flow is parsed: a missing file ("runFlow file not found") or a cycle ("runFlow cycle: a.yaml -> b.yaml -> a.yaml") is reported before anything runs. A path with `${…}` is resolved and parsed when the step runs.
- **Hooks.** A file subflow's own `onFlowStart` and `onFlowComplete` run around its body.
- **Step ids.** Steps inside get dotted ids: `2.1`, `2.2`, …; a subflow's hooks are `2.start.1` and `2.complete.1`.
- **Keeping subflows out of runs.** Put subflows in a folder the project doesn't scan, such as `.qa/subflows/`, so they don't also run on their own.

#### `repeat`

Repeats commands. Map form only.

| Option | Meaning |
|---|---|
| `times` | How many times, at least 1 |
| `while` | A [condition](#74-conditions-and-variables), checked before each iteration |
| `commands` | Required: the commands to repeat |

```yaml
- repeat:
    times: 3
    commands:
      - tapOn: Add
- repeat:
    while: {notVisible: "Item 40"}
    commands:
      - scroll
```

- **`times`, `while`, or both** (at least one). With both, it stops at whichever comes first.
- **Cap.** A `while` without `times` stops after 100 iterations with `repeat_limit`.
- **Step ids** are `<step>.<iteration>.<n>`, for example `4.2.1`. The step's note is `<n> iteration(s)`.

### Rejected Maestro commands

These fail at parse time with "X is not supported by QAFlow":

`addMedia`, `assertDarkMode`, `assertLightMode`, `assertNoDefectsWithAI`, `assertTrue`, `assertWithAI`, `clearKeychain`, `copyTextFrom`, `evalScript`, `extractTextWithAI`, `inputRandomEmail`, `inputRandomNumber`, `inputRandomPersonName`, `inputRandomText`, `pasteText`, `retry`, `runScript`, `setAirplaneMode`, `setClipboard`, `setDarkMode`, `setLocation`, `setPermissions`, `startRecording`, `stopRecording`, `toggleAirplaneMode`, `toggleDarkMode`, `travel`.

Any other unknown name suggests the closest known one when it is close enough ("unknown command tapon (did you mean tapOn?)").

## 7.2 Selectors

| Field | Matches | Example |
|---|---|---|
| *(plain string)* | Same as `text` | `tapOn: Save` |
| `text` | The element's text, exactly or as a full regular expression | `{text: "Item \\d+"}` |
| `id` | A `ValueKey<String>` value **or** a `Semantics(identifier:)` | `{id: login}` |
| `type` | The widget's class name | `{type: Checkbox}` |
| `index` | Picks one when several match (0-based, in tree order) | `{type: Checkbox, index: 2}` |
| `enabled` | Only enabled (`true`) or disabled (`false`) controls | `{id: login, enabled: true}` |
| `childOf` | Inside an element matching another selector, at any depth | `{text: Delete, childOf: {id: row-7}}` |

- **Fields combine.** Every field given must match.
- **Text as a regular expression.** The value is tried as a full-match Dart regular expression *and* as literal text, so `Item 1` matches exactly and `Item \d+` matches "Item 42". A value that is not a valid regular expression (`Save (draft`) matches literally.
- **Innermost match wins.** When matches are nested, the innermost is used, so a `Semantics` wrapper and the button inside it count as one.
- **One match needed.** An action needs exactly one match. With more, it fails with `ambiguous`: "3 widgets match …; add index or narrow the selector".
- **Required field.** A selector needs at least one of `text`, `id`, `type` or `childOf` ("a selector needs text, id, type or childOf").
- **Variables.** `text` and `id` are substituted; `type` and `index` are not.
- **Rejected Maestro fields:** `above`, `below`, `leftOf`, `rightOf`, `checked`, `focused`, `selected`, `containsChild`, `containsDescendants`, `traits`, `width`, `height` and `tolerance` ("selector field X is not supported"). Any other unknown field is "unknown selector field X".

Prefer `id` for anything whose text can change: translations, counts, wording. QAFlow Studio's Inspect & record and its editor's Pick from app rank suggestions in that order and show how many elements each one matches.

## 7.3 Key names for `pressKey`

| Kind | Names |
|---|---|
| Letters and digits | `a`–`z`, `0`–`9` |
| Editing | `enter`, `tab`, `escape`, `space`, `backspace`, `delete` |
| Navigation | `arrowup`, `arrowdown`, `arrowleft`, `arrowright`, `home`, `end`, `pageup`, `pagedown` |
| Function keys | `f1`–`f12` |
| Modifiers (as keys or before `+`) | `shift`, `ctrl`, `alt`, `meta` |
| Modifier aliases (only before `+`) | `mod` (⌘ on macOS, Ctrl elsewhere), `cmd`/`command` (= `meta`), `control` (= `ctrl`), `option` (= `alt`) |

- **Combinations** join with `+`, modifiers first: `mod+shift+z`. The modifiers go down, the key goes down and up, then the modifiers come up in reverse order.
- **Case:** names are not case-sensitive.
- **Shifted characters:** `shift` plus a digit types the US-layout symbol, so `shift+7` types `&`; `shift` plus a letter types the capital. Other keyboard layouts aren't modelled.
- **The lists live in code:** `KeyChord.knownModifiers` and `KeyChord.namedKeys` in [`qaflow_protocol/lib/src/key_chord.dart`](../../packages/qaflow_protocol/lib/src/key_chord.dart) (the editor suggests `namedKeys`), and the agent's table in [`qaflow_agent/lib/src/input/keyboard.dart`](../../packages/qaflow_agent/lib/src/input/keyboard.dart). A test resolves every named key through the agent.

## 7.4 Conditions and variables

**Conditions**, for `runFlow: {when: …}` and `repeat: {while: …}`:

| Key | True when |
|---|---|
| `visible: <selector>` | A match is visible now (settles, then checks once; not retried) |
| `notVisible: <selector>` | No visible match |
| `platform: macOS` | Running on that platform (`iOS`, `Android`, `macOS`, `Windows` or `Linux`; any case), as the app reports it |
| `true: ${FLAG}` | The value is `true` after substitution; `false` makes it not hold; anything else is a `bad_request` error |

A condition needs at least one key. When several keys are given, all must hold. `true:` takes a plain `${NAME}` (or a literal); an expression such as `${MODE == "demo"}` is rejected at parse time.

**Variables.** `${NAME}` is replaced when the step runs. Names are letters, digits and `_`, not starting with a digit. An undefined name fails the step with `bad_request`, "undefined variable NAME". Only plain names are allowed: `${a+b}` is rejected at parse time ("JavaScript expressions are not supported"). Where values come from, highest priority first:

1. a `runFlow` step's `env:`;
2. the run's variables: the project file's `flows.env`, where `qa test --env NAME=value` values (or, in QAFlow Studio, the stored secret values) replace any with the same name;
3. the subflow's own header `env:`;
4. the calling flow's variables.

For a top-level flow, the run's variables win over the flow's header `env:`.

**Secrets** are listed by name in `flows.secrets` and given values outside the project file:

- **`qa test`:** `--env PASSWORD=…`, or an environment variable called `PASSWORD`. A secret with no value stops `qa test` before launch with a usage error (exit 64).
- **QAFlow Studio:** a value stored on the machine, which it asks for the first time.

Step titles keep `${PASSWORD}` unexpanded. Screenshots and element dumps can still show what was typed.

## 7.5 The flow file header

| Key | Meaning |
|---|---|
| `name` | Name in reports, the console and QAFlow Studio. Default: the file name without extension |
| `tags` | A list (or a single string) for `--include-tags`/`--exclude-tags` and `flows.includeTags`/`excludeTags` |
| `env` | Variables for this flow (names must be identifiers; values cannot be empty) |
| `onFlowStart` | Commands run before the body (ids `start.N`). If one fails, the body is skipped |
| `onFlowComplete` | Commands run after the body even when it failed (ids `complete.N`). If one fails, the flow fails |
| `appId` | Maestro's; accepted and ignored |

The header is separated from the body by `---`. Without a header a file is just the command list.

## 7.6 The `qa` command line tool

Run `qa` from the toolkit's root folder as `dart run qaflow:qa <command> [options]` ([`packages/qaflow/bin/qa.dart`](../../packages/qaflow/bin/qa.dart)). Chapter 2 explains what happens underneath.

| Command | Does | Exit code |
|---|---|---|
| `qa test [flows or folders]` | Runs flows and writes `results.json`, `junit.xml` and `report.html`, then prints `Report:` and `JUnit:` paths | 0 if every flow passed (flaky counts as passed) and the run was not cut short; 1 otherwise |
| `qa validate [flows or folders]` | Parses flows and reports problems as `file:line:column: message`, or `N flow file(s) OK`. With no paths it also checks the project file (`<file> OK`) and uses its flow folders | 0 if all are valid, 1 otherwise |
| `qa ping` | Launches the app, prints the agent's ping result and the settle result, saves `<out>/ping.png`, stops | 0 |
| `qa smoke` | Runs the built-in demo-app scenario, writing screenshots and `smoke.log` into `<out>` | 0 if every step passed, 1 otherwise |
| `qa host` | Runs a QA host: launches apps and boots devices on this machine for `qa` or QAFlow Studio on another one ([chapter 11](11-remote-hosts.md)) | Runs until stopped |

**Flow paths.** `qa test` and `qa validate` take flow files and folders. A folder contributes the `.yaml`/`.yml` files directly in it (not subfolders), sorted by name, skipping `project.yaml` and `config.yaml`. With no paths they use the project file's `flows.folders`.

**Options for `qa test`, `qa ping` and `qa smoke`:**

| Option | Default | Meaning |
|---|---|---|
| `--config <file>` | `./.qa/project.yaml` if present | The project file; must sit inside a `.qa` folder |
| `--project <dir>` | from the config | Launch from this source folder (replaces the config's app) |
| `--binary <path>` | from the config | Launch this prebuilt binary or `.app` (replaces the config's app). Not on mobile devices |
| `--mode debug\|profile` | config, else `debug` | Build mode. iOS simulators run debug only |
| `--device <id>` | config, else this computer | `macos`, `windows`, `linux`, `flutter-tester`, `ios:<simulator name or UDID>` (e.g. `ios:iPhone 17 Pro`) or `android:<AVD name or emulator serial>` (e.g. `android:qa_pixel_baklava`, `android:emulator-5554`). A shut-down simulator or AVD is booted and left running; a serial must already be running |
| `--entrypoint <file>` | config, else `lib/main_qa.dart` | The entrypoint that installs the agent |
| `--flutter <path>` | found automatically | Absolute path to the `flutter` executable. Otherwise: `FLUTTER_ROOT`, fvm's default, `PATH`, then common install folders |
| `--host <url\|none>` | the config's `host:` | Run the app on a QA host, e.g. `ws://127.0.0.1:7777` through an SSH tunnel. `none` runs on this machine even when the project file names a host |
| `--host-project <dir>` | the config's `host.project` | The project folder (the one holding `.qa/`) on the host. Alone, it uses the default URL `ws://127.0.0.1:7777`. With a host, `--project` and `--binary` are paths on the host |
| `--out <dir>` | `<app root>/qa-out` with a project file, else `./qa-out` | Where run folders (or `ping`/`smoke` output) go |

Pass at most one of `--project` and `--binary`; with neither, a project file is needed. With no `--device` and no `device:` in the project file, a host run uses the host's own desktop.

**Additional options for `qa test`:**

| Option | Default | Meaning |
|---|---|---|
| `--include-tags a,b` | config, else all | Run only flows with one of these tags |
| `--exclude-tags a,b` | config, else none | Skip flows with any of these tags |
| `--env NAME=value` | none | A flow variable; repeatable; wins over the project file's `flows.env` |
| `--retries <n>` | config, else 0 | Extra attempts for a failing flow (a pass on a retry is "flaky") |
| `--screenshots failures\|all\|none` | config, else `failures` | When to save screenshots |
| `--baselines record\|strict\|update` | config, else `record` | What `assertScreenshot` does with a missing or present baseline |
| `--verbose` | off | Also print app output (`[app]` lines) and VM service details (`[vm]` lines) |

`qa test` parses every flow before launching anything; any parse error prints `file:line:column: message` and exits 1. If the tag filters leave nothing, it prints `qa: no flows to run` and exits 1.

**Options for `qa validate`:** only `--config <file>`, used when no paths are given.

**Options for `qa host`:**

| Option | Default | Meaning |
|---|---|---|
| `--port <n>` | `7777` | Port to listen on, on `127.0.0.1` only |
| `--token-file <file>` | `~/.qa/host-token` (`%USERPROFILE%` on Windows) | The access token; created (mode 600) and printed once if missing |

**Exit codes:**

| Code | When |
|---|---|
| 0 | Success |
| 1 | Flows failed, errored or were not run; flow parse errors; no flows selected; `validate` found problems; a project file error (`<file>:<line>:<col>: …`); a launch failure (`qa: launch failed: …`); a QA host error (`qa: …`); an agent error (`qa: agent error: …`, `qa: step failed: …`); a missing flow path (`qa: invalid argument: …`); `qa host` could not listen |
| 64 | Usage mistakes: an unknown command or option, a bad option value, both `--project` and `--binary`, no app and no project file, a missing secret value, a bad `--env` assignment or `--retries`, a bad `--host` URL or `--host none` with `--host-project`, a device the mode or app does not support (iOS with profile, a prebuilt app on mobile) |
| 128 + n | Stopped by signal n: 130 for SIGINT (Ctrl+C), 143 for SIGTERM |

**Stopping `qa`.** The first SIGINT or SIGTERM stops what the command started: `qa test` stops its run (the step in flight and the app) and waits for the reports to be written, `ping` and `smoke` stop their session, `qa host` closes and stops its apps. That is bounded at 15 s; then any launched process still running is killed with its whole process tree (SIGTERM, then SIGKILL), and `qa` exits with 128 + the signal number. A second signal skips the wait: it SIGKILLs those trees (bounded at 2 s) and exits at once. Windows has no SIGTERM to watch, so only Ctrl+C is handled there ([`launch/termination.dart`](../../packages/qaflow/lib/src/launch/termination.dart)).

**Environment variables:**

| Variable | Effect |
|---|---|
| `QA_HOST_TOKEN` | The token for a QA host. Never read from the project file (a `token:` key there is an error). Missing with a host: `Set QA_HOST_TOKEN to the token qa host printed` |
| `QA_BASELINE_KEY_SUFFIX` | Appends `-<suffix>` to the screenshot baseline device key (CI uses `ci`) |
| `QA_ANDROID_BOOT_TIMEOUT` | Seconds; replaces the 180 s Android emulator boot limit |
| `QA_IOS_BOOT_TIMEOUT` | Seconds; replaces the 120 s iOS simulator boot limit |
| `ANDROID_HOME`, then `ANDROID_SDK_ROOT` | The Android SDK, when it is not in the default place |
| `FLUTTER_ROOT` | Where to look for Flutter before fvm and `PATH` |
| `<secret name>` | The value of a secret listed in `flows.secrets`, when `--env` does not give one |

```bash
dart run qaflow:qa validate --config ../my_app/.qa/project.yaml
dart run qaflow:qa test --config ../my_app/.qa/project.yaml --include-tags smoke --env PASSWORD=$PASSWORD
dart run qaflow:qa test ../my_app/.qa/flows/login.yaml --binary build/my_app.app --mode profile
dart run qaflow:qa test --config ../my_app/.qa/project.yaml --device "ios:iPhone 17 Pro"
dart run qaflow:qa test --config ../my_app/.qa/project.yaml --baselines strict
QA_HOST_TOKEN=… dart run qaflow:qa test --config ../my_app/.qa/project.yaml --host ws://127.0.0.1:7777 --host-project 'C:\src\my_app'
dart run qaflow:qa host --port 7777
```

## 7.7 QAFlow Studio commands and shortcuts

### Menu commands

`StudioCommand` in `app/commands.dart` lists them; the native menu in `MainFlutterWindow.swift` gives them their keys.

| Command | Shortcut | Menu | Available when |
|---|---|---|---|
| New flow | ⌘N | File | On the Flows screen with a valid project |
| Run flow | ⌘R | Run | On the Flows screen, the selected flow is valid and saved, and nothing blocks a run |
| Run all flows | ⇧⌘R | Run | On the Flows screen and at least one flow is valid |
| Stop run | ⌘. | Run | A run is in progress. Press it again to force-stop |
| Command palette | ⌘K | View | Always |
| Flows / Inspect & record / Runs / Project settings | ⌘1 / ⌘2 / ⌘3 / ⌘4 | View | A project is open |
| Studio settings | ⌘, | QAFlow Studio | Always |

Menu items that can't be used right now are greyed out. The ⌘K palette lists the same commands, plus every flow and the 20 most recent runs.

### Flow editor

The YAML editor on the Flows screen. On Windows and Linux, read Ctrl for ⌘.

| Keys or gesture | Does |
|---|---|
| Typing | Suggestions open by themselves for command names, keys and values (after a space) |
| Ctrl+Space | Opens suggestions wherever the caret is (Control on every platform); never types a space |
| ↑ / ↓ | Move through suggestions |
| Enter or Tab | Accept the highlighted suggestion (on key down; held repeats are swallowed) |
| Click a suggestion | Accept it |
| Esc | Close suggestions |
| Moving the caret | Closes suggestions |
| ⌘⇧E | **Pick from app**: opens the element picker, which starts or reuses an inspect session; click an element, choose a command (`tapOn`, `assertVisible`, `assertNotVisible`, `scrollUntilVisible`, `longPressOn`, `doubleTapOn`) and a ranked selector, and Insert writes the step. Also a button in the editor header |
| ⌘⇧X | **Extract to subflow**: moves the selected whole steps into a new file (in `.qa/subflows/` by default) and replaces them with `runFlow: <path>`. Also in the right-click menu as "Extract to subflow…" |
| ⌘-click a `runFlow` path | Opens that subflow (the path underlines while ⌘ is held over it). A missing file is offered for creation; a folder or a path outside the app is refused |
| Rest the mouse on a command or key | Shows its documentation from `FlowSchema` after 400 ms; any key press hides it |

Suggestions, templates, hover docs and the picker's value kinds all come from `FlowSchema`, so a command added there appears in the editor without editor changes. Element suggestions come from the open inspect session, else the last one, else the newest run's `elements-*.json` dumps. Chapter 4 describes the editor in full.

### Other keys

| Where | Keys |
|---|---|
| Screenshot viewer | ← and → move between screenshots; Esc closes |
| Command palette | ↑ and ↓ move; Enter runs; Esc closes |
