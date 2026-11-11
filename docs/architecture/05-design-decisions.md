# 5. Design decisions

Each of the main choices that shape the toolkit is recorded here with the problem it solved, the alternatives considered, and what it costs. Most were agreed during the design specs in the design specs. The rest were made while building and are marked *as built*. D1–D16 come from the first rounds (the agent, the flow runner and QAFlow Studio); D17–D25 from the later rounds (mobile targets, screenshot assertions, the flow editor, remote hosts and process clean-up).

## D1. Drive the app from inside, over the Dart VM service

**Problem.** A UI test needs to find widgets, act on them and see the result, reliably, on three desktop platforms.

**Options.**

1. **OS-level automation** (macOS Accessibility, Windows UI Automation, AT-SPI): one implementation per platform, sees only what the accessibility tree exposes, and needs OS permissions.
2. **`flutter_driver` / `integration_test`:** the test code is compiled into the app, it's tied to the `flutter test` harness, and it can't be driven interactively from another app such as a studio.
3. **An in-app agent answering RPCs over the VM service** that debug and profile builds already open.

**Choice: option 3.** The agent sees the real widget tree, real text, real keys and semantics. It injects input through the same framework entry points real devices use, and it costs one extra file (`lib/main_qa.dart`). The same JSON protocol serves the CLI, CI and an interactive studio.

**Cost.**

- **Release builds can't be tested.** There's no VM service in release; use profile builds, which are AOT-compiled.
- **No visibility into native windows.** Anything outside Flutter's tree (native file dialogs, OS menus) is invisible to the agent.
- **Hidden windows pause frames.** The app's window must stay visible while it's driven, because the OS stops producing frames otherwise. The agent detects that and reports `not_ready` instead of hanging (chapter 1.4.7).

## D2. A separate `main_qa.dart` entrypoint, plus a release guard

**Problem.** Test hooks must never ship to users.

**Choice.**

- **Entrypoint.** The agent is imported only from a second entrypoint that the driver launches (`-t lib/main_qa.dart`). Normal release builds compile `main.dart`, which never references it.
- **Guard.** `QaAgent.install()` also throws in `kReleaseMode`, in case `main_qa.dart` is built in release by mistake.

**Cost.** Prebuilt binaries must be built with `-t lib/main_qa.dart`. A plain `flutter build` has a VM service but no `ext.qa.*` hooks.

## D3. Three packages with strict dependency rules

**Choice.**

| Package | Is | Depends on |
|---|---|---|
| `qaflow_protocol` | the wire format, pure Dart | nothing |
| `qaflow_agent` | the in-app side | Flutter and the protocol |
| `qaflow` | everything else | the protocol, never Flutter |

**Why.** `qaflow` must run where there is no Flutter engine: the CLI and CI. The shared protocol package makes "the two sides disagree about a JSON field" a compile error on one side or the other, instead of a runtime surprise.

## D4. The agent reports; the driver decides

**Choice.**

- **The agent answers every call immediately** with the current state of the app, or a typed error code (`not_found`, `obscured`, …).
- **The agent never throws across the boundary.** It always replies with an envelope.
- **All waiting and retrying happens in the driver:** retry `not_found`, `ambiguous`, `not_ready`, `off_screen` and `obscured` every 100 ms for up to 10 s, settling before each attempt.

**Why.** Timing policy lives in one place, in pure Dart, testable with a fake transport. The agent stays small and stateless. The error codes make "why did this step fail" precise: "it's covered by a dialog" (`obscured`) is different from "it doesn't exist" (`not_found`).

**Related:** the driver **never scrolls on its own** to fix `off_screen`. Scrolling is an explicit step, so flows do what they say.

## D5. Act like a user: visible-centre point plus a hit test

**Choice.** Before acting on an element, the agent checks four things:

1. it has a laid-out box;
2. some of it is visible inside the view and its scroll viewports;
3. it acts on the centre of the **visible** part;
4. a hit test at that point reaches the element, not something covering it.

Disabled controls are `not_ready`.

**Why.** A test that taps through a modal scrim, or taps a button scrolled under an app bar, passes when a person couldn't do the same thing, which is exactly the bug a UI test should catch. These checks make the agent's notion of "can be tapped" match a person's.

## D6. Settle by "idle or stable", not by sleeping

**Choice.** `waitForIdle` returns when no frame is scheduled and no animations are running. Otherwise it returns when the element snapshot has been unchanged for three frames **and** 500 ms have passed. A timeout is a warning, not a failure.

**Why.**

- **No sleeps.** Fixed sleeps are slow and still flaky.
- **Not "idle" alone.** Strict idleness never happens on screens with endless animations, such as spinners.
- **The 500 ms floor** exists because an opacity fade changes no geometry, so "unchanged for three frames" alone can fire too early.

## D7. Maestro-compatible YAML flows

**Problem.** Tests should be readable by non-developers and portable for teams that already know mobile UI testing.

**Choice.**

- **Format.** The flow format follows Maestro's: header, `---`, then a command list, with `tapOn`, `assertVisible`, `runFlow` and so on.
- **Unsupported commands.** Maestro commands with no desktop meaning, JavaScript expressions and unsupported selector fields are **rejected at parse time** with a clear message, never ignored.
- **Text selectors.** Text is "literal or full regex".
- **`childOf`** means any ancestor.

**Why rejecting matters.** Silently skipping an unsupported command would make a flow pass while testing less than it claims.

**Cost.** It's a subset of Maestro. Flows that rely on JavaScript, relative-position selectors or mobile-only commands need rewriting.

## D8. Reset the app before every flow

**Choice.** Before every flow except the first, and before every retry, the runner resets the app: a hot restart in debug (about a second), or a relaunch in profile or for a prebuilt binary. `launchApp` on an app that was just reset does nothing ("app already fresh"). An optional `onReset` hook, given to `QaAgent.install`, wipes persisted state for `clearState`.

**Why.** Flows must not depend on each other's leftovers, and retries must start clean or "flaky" is meaningless. Making the redundant `launchApp` a no-op keeps Maestro-style flows, which all start with `launchApp`, from paying for two restarts.

**Cost.** Persisted state (files, preferences) survives a hot restart unless the app supplies `onReset`.

## D9. One run, one folder, three reports from one model

**Choice.** Every run writes `results.json`, `junit.xml` and `report.html` into its own `qa-out/<UTC timestamp>/` folder, with screenshots and element dumps beside them. All three are generated from one `RunResult` built from the event stream.

**Why.**

- **`results.json`** is the source of truth for tools; QAFlow Studio's history reads nothing else.
- **`junit.xml`** plugs into every CI system.
- **`report.html`** is for people, works offline and needs no JavaScript.
- **One model** means the three never disagree.
- **Relative links** mean a zipped run folder is self-contained.

## D10. Infrastructure errors end the run

**Choice.** Any error that means the app or its connection is gone (a launch failure, a lost VM service, a call unanswered for 60 s) carries an `rpcCode` marker. It fails the current step, marks the flow `error` and every remaining flow `notRun`, and still writes the reports.

**Why.** Continuing would produce dozens of misleading "element not found" failures against a dead app. One clear error naming the step where things broke is far more useful.

## D11. Project settings in the repository, machine settings on the machine

**Choice.**

- **`.qa/project.yaml` lives in the app's repository** and holds everything about the project: how to launch, flow folders, variables, tags, retries.
- **QAFlow Studio's own settings** hold only machine-local things: recent projects, where Flutter is, the theme, secret values.

**Why.** The CLI, CI and the studio read the same file, so "passes in the studio" and "passes in CI" mean the same thing, and settings changes go through code review.

**Consequences.**

- **Flutter's location is never stored in the project.**
- **Secrets are listed by name only.** Values come from `--env`, environment variables, or the studio's per-machine store.
- **The studio is the only writer**, and it edits only changed keys with `yaml_edit`, so hand-written comments and formatting survive.

## D12. QAFlow Studio runs `qaflow` in-process

**Options.** Bundle the `qa` CLI and parse its output, or import `qaflow` and consume its typed event stream.

**Choice: import it.**

**Why.** The studio gets typed events instead of scraped text, and live previews without writing them to disk. Most importantly, every behaviour the studio relies on lives in `qaflow`, where the CLI shares it and `qaflow`'s tests cover it. The studio never talks to the agent directly.

**Cost.** A run shares the studio's process. A bug that hangs the runner's isolate would hang the UI. In practice runs are I/O-bound and every wait is bounded.

## D13. Inspect through a mirror; record by performing first

**Choice.**

- **Pointing.** The studio shows a screenshot of the app with the element tree overlaid and maps clicks back to app coordinates. Clicks are not intercepted on the real window.
- **Recording.** In record mode, each action is **performed on the app first, and written to the flow only if it succeeded.**

**Why.**

- **Mirror instead of the real window:** intercepting clicks on another app's window would need OS input monitoring, permissions and per-platform code. The mirror needs no protocol changes at all; it only uses existing calls.
- **Perform-then-record** guarantees every recorded step replays: a selector that doesn't work is never written.

**Cost.** The mirror is a snapshot, refreshed after each action and on demand, not a live video.

## D14. Rank selectors for robustness, and show how many each matches

**Choice.** Suggestions rank:

1. stable ids (`ValueKey<String>` or a `Semantics` identifier);
2. the element's own text;
3. text scoped by an ancestor id (`childOf`);
4. type plus index.

Each suggestion shows its match count, and a best suggestion that isn't unique is flagged.

**Why.** Ids survive copy changes, translations and layout changes; type plus index breaks when anything is added above. Showing the count makes ambiguity visible before it becomes a flaky test.

## D15. Riverpod providers with every OS effect injectable (*as built*)

**Choice.** All state is in Riverpod 3 providers. The file picker, OS actions (open, reveal, trash), the run starter, the inspect-session factory, the device manager, the remote-host connection and file watching are all providers or overridable hooks.

**Why.** Every screen can be widget-tested against the real app shell with fakes: no real processes, dialogs or file watchers. About 590 studio tests run headless in around 20 seconds, on any OS. Even `terminationSignalsProvider` and `processExitProvider` are providers, so a widget test never sees a real signal or exits the test process.

## D16. Desktop-native chrome and commands (*as built*)

**Choice.**

- **Title bar.** It is transparent, with Flutter headers acting as drag regions over a native channel.
- **Commands.** They are defined once in Dart (`StudioCommand`) and surfaced three ways, all from one registry that knows what's available on the current screen: native menu items with real key equivalents, the ⌘K palette, and on-screen buttons.
- **Notifications and badge.** Background runs post notifications and a Dock badge.

**Why.** A desktop tool should behave like one: shortcuts listed in the menu bar, items greyed out when unavailable, and a window that remembers where it was. One registry means a menu item, a shortcut and a button can never disagree about whether an action is allowed.


## D17. Mobile targets through a device layer over the native tools

**Problem.** Flows should also run on an iOS simulator and an Android emulator, from the CLI and from QAFlow Studio, without a separate tool.

**Options.**

1. **Lean on Flutter's tooling** (`flutter emulators`, `flutter devices`) for discovery and boot, and simulate orientation and deep links inside the app.
2. **A hybrid** of Flutter's tooling and native tools.
3. **A device layer in `qaflow` over the native tools** (`xcrun simctl`, `emulator`, `adb`) that owns discovery, boot, readiness, orientation and deep links ([`device/`](../../packages/qaflow/lib/src/device/)).

**Choice: option 3.** Devices are named in the project file (`ios:<simulator name or UDID>`, `android:<AVD or emulator serial>`), booted on demand, waited for until ready, and left running after the run. The app is still launched with `flutter run`. On iOS and Android the agent sends `PointerDeviceKind.touch`, so `swipe` scrolls lists as it does in Maestro. Four mobile commands were added: `back`, `hideKeyboard`, `setOrientation` and `openLink`. QAFlow Studio got full parity: the grouped device picker, runs, and Inspect & record with Back, Hide keyboard and Rotate.

**Why.** `flutter devices` has no readiness signal, and simulating rotation or a deep link inside the app does not test what a user does. The native tools give a real boot, a real rotation (`user_rotation` on Android) and a real `openurl`.

**Cost.**

- **iOS simulators run in debug only.** Flutter refuses profile mode there; the config rejects it up front and Studio forces debug.
- **No prebuilt mobile apps and no physical devices.** `binary` with an `ios:`/`android:` device is refused.
- **Cold boots are slow** (minutes on CI). The boot limits are configurable (`QA_IOS_BOOT_TIMEOUT`, `QA_ANDROID_BOOT_TIMEOUT`).
- **iOS rotation** goes through the app's preferred orientations, so the simulator's own chrome does not turn; Android waits up to 10 s per rotation for the view to change shape.
- **System alerts can't be driven**, so custom-scheme `openLink` on iOS stops at the "Open in …?" alert.

## D18. Screenshot baselines per device key, compared in `qaflow`

**Problem.** `assertScreenshot` needs a reference image, but a Mac, a simulator and a CI runner render the same screen differently.

**Choice.**

- **Baselines live in the repository** at `<app root>/.qa/baselines/<device key>/<flow slug>/<name>.png`.
- **The device key** is the platform, device name and OS version, cleaned and joined with `-` (`ios-iPhone_17_Pro-iOS_26.5`, `android-qa_pixel_baklava-Android_15_API_35`). Desktop keys carry the host OS version (`macos-27.0`). `QA_BASELINE_KEY_SUFFIX` adds a part, so CI records its own set (`…-ci`).
- **The flow slug** comes from the flow file's path under `.qa/` (`flows-screenshot`), not from its `name:`, so renaming a flow's title does not orphan its baselines.
- **Modes:** `record` (default; a missing baseline is written and the step warns), `strict` (a missing baseline fails) and `update` (always overwrite).
- **The comparison runs in `qaflow`**, with the pure-Dart `image` package, inside `Isolate.run` so QAFlow Studio's UI isolate never stalls. Dynamic areas are handled by a threshold plus `ignore` selectors whose rectangles are blanked in both images.

**Options rejected.** Comparing inside the app (megabytes over the VM service, harder to test, tied to the agent version) and an external diff tool (a native install on every machine).

**Why per device key.** Each machine type gets its own set and they never fight over one image. An OS upgrade starts a new set rather than failing every comparison.

**Cost.** Baselines are tens to hundreds of KB each in git. Two Macs on the same macOS version share `macos-27.0` even if one has a different screen scale, which shows up as a size mismatch (chapter 9). A renamed flow file moves its baselines. QAFlow Studio has no baseline-management screen; it shows comparisons and **Accept as baseline** in run detail.

## D19. Editor suggestions driven by a schema checked against the parser

**Problem.** The YAML editor should suggest commands, keys and values that are valid where the caret is, while the text is half-written and does not parse.

**Options.**

1. **More line regexes** in the editor, each knowing a few commands.
2. **A YAML-aware engine** that parses the document. It fails exactly when it is needed most, mid-edit.
3. **A text-only caret analysis plus a schema of the flow language.**

**Choice: option 3.**

- `FlowSchema` in `qaflow` describes every command, its forms, keys, value kinds, descriptions and examples, plus the header, selector and condition keys.
- `contextAt` in QAFlow Studio works out from the text alone what the caret is typing, the enclosing commands and the key path.
- `suggestionsAt` combines the two with the project (flow files, variables, secrets, baseline names) and an element index.
- Agreement tests (`packages/qaflow/test/flow_schema_test.dart`) read the parser's accepted key sets from `parser.dart` and compare them with the schema, and parse every schema example. If the parser gains a key, the test fails until the schema has it.
- The same schema feeds the hover docs and the step templates, so there is one source of truth for the language's shape.

**Why.** The schema can't drift from the parser without a failing test, and the parser stays the only validator, so suggestions never contradict the error underline.

**Element suggestions without a live app.** The element index uses the live inspect session, else the last inspect session of the project, else the newest run's element snapshots, so ids and texts can be suggested even when nothing is running.

**Cost.** `contextAt` reads indentation leniently and does not follow multi-line flow maps; a header written after body items with no `---` counts as body.

## D20. Authoring tools as pure text functions

**Choice.** Inserting a picked selector, finding a `runFlow` path, working out extractable steps, building the subflow and finding hover docs are pure functions over text and offsets in `editor_actions.dart`. The widget only wires them to the field. Extracting steps does **not** parameterise them: `${VAR}` keeps working because `runFlow` passes the caller's env through.

**Why.** Each can be unit-tested exhaustively on odd YAML (CRLF lines, comments, flow maps, the header) without pumping a widget, and the editor stays thin. Not parameterising keeps extract predictable; the user can add `env:` by hand.

**Cost.** Renaming a subflow does not update its callers, and an extracted subflow keeps the original's line endings.

## D21. The element picker lives in the editor, not in Inspect & record

**Problem.** Writing a step by hand means finding a selector in Inspect & record and copying it back.

**Options.**

1. **An "Insert into editor" button in Inspect & record**, which sends the selected selector to whichever flow is open.
2. **A picker dialog inside the editor** (⌘⇧E) that shows the live mirror and inserts at the caret.

**Choice: option 2.** `showElementPicker` reuses the Inspect & record session and mirror, but calls `selectAt(x, y, record: false)`, so a click never taps or records, even during a recording. Insert writes the selector where the caret is, as a value, as a step, or as a new step after the caret's step.

**Why.** The user never leaves the flow, and the insert position is unambiguous (the caret). One session serves both screens, so there is still only one app under test. A button in Inspect & record would have to guess which file and where.

**Cost.** The picker shares the inspect session's rules: a run blocks it, and the app's window must be visible for the mirror to update.

## D22. Remote hosts: a `qa host` daemon reached over an SSH tunnel

**Problem.** Run flows from QAFlow Studio or `qa` on one machine (a Mac) against an app on another (a cloud Windows machine reached by Remote Desktop). The runner launches the app itself, on its own machine, and reaches the agent over the app's VM service, which listens on loopback only.

**Options.**

1. **An attach mode:** the user starts the app on the other machine and the runner attaches to its VM service. The runner would lose launching, resetting between flows and booting devices, which every flow relies on (D8).
2. **Expose the app's VM service** on the network. The VM service runs arbitrary code in the app; exposing it, even with its auth code, is a remote code execution port.
3. **A small daemon on the other machine** that launches apps and boots devices with the existing launchers and device code, and proxies the app's VM-service WebSocket, reached through an SSH tunnel.

**Choice: option 3** ([chapter 11](11-remote-hosts.md)). `qa host` listens on 127.0.0.1 only and requires a token on every connection. The client reaches it through `ssh -L`. One tunnelled port carries both the control channel (JSON-RPC over WebSocket) and `/vm/<appId>`, the proxy to the app's VM service. On the client, `RemoteLauncher` and `RemoteDevices` plug into the existing `AppLauncher` and `Devices` seams, so `QaDriver`, `VmConnection` and the flow runner are unchanged. Flows stay on the client and are parsed there; only the app's source lives on the host, at a configured path.

**Why.** No port is exposed to the network, SSH does authentication and encryption, and the runner keeps full control of the app's lifecycle. Everything the driver needs already travels over the VM-service WebSocket, so proxying it is enough.

**Cost.**

- **The token is powerful.** Anyone with it and a way to the port can run programs as the host's user; `qa host` says so when it starts. It lives in `QA_HOST_TOKEN` or Studio settings, never in `project.yaml`.
- **The user manages the tunnel.** Studio does not start SSH, sync source, or use TLS.
- **Windows sessions.** `qa host` must run inside the logged-in desktop session: apps started from an SSH session have no desktop. Disconnecting RDP without `tscon` stops the desktop rendering.

## D23. One client per host

**Choice.** A `qa host` serves one client at a time. A second control socket is upgraded and closed at once with code 4000 and `QA host is in use by another client`. When a client drops, its apps keep running for a 10 s grace period, so a reconnecting client can take them over; after that they are stopped. In QAFlow Studio a per-host `HostGate` keeps device listings and sessions from colliding: a listing opens its own short connection, a session waits for a listing in flight, and while a session holds the host the picker shows the last good list without dialling.

**Why.** One desktop and one set of devices can't sensibly be driven by two clients at once, and a single owner makes clean-up on disconnect simple: whatever the client launched is stopped.

**Cost.** A second machine, or a `qa` command while Studio is running on the same host, is refused rather than queued. Any holder of the token who connects within the grace inherits the previous client's apps.

## D24. Stop the whole process tree, found with `ps` (*as built*)

**Problem.** `flutter run` starts the app as its own child. On macOS the app outlived a kill of `flutter run`, and a `qa` or Studio that was killed (Ctrl-C, SIGTERM, the end of a self-test) left both running.

**Options.**

1. **Kill the process group.** Dart starts children in the parent's process group, and macOS has no `setsid` to give a child its own group, so a group kill would also hit `qa` itself.
2. **Read the process tree from `ps` and signal every descendant.**

**Choice: option 2** ([process_tree.dart](../../packages/qaflow/lib/src/launch/process_tree.dart)). `ProcessTree` reads `ps -A -o pid= -o ppid= -o lstart=` *before* signalling anything (an orphan is reparented and can no longer be found from its old parent), sends SIGTERM to the root and every descendant, waits up to 3 s, then SIGKILLs whatever is left. Each descendant is recorded with its start time, and a pid is only signalled while its start time still matches, so a pid reused by an unrelated process (on macOS launchd parents many) is left alone. Windows uses `taskkill /PID <pid> /T /F`. `exitOnTermination` makes SIGINT and SIGTERM behave like a normal quit: stop the active session or run (bounded), kill any launched process still alive, then exit with 128 + the signal number; a second signal SIGKILLs at once. Both `qa` and QAFlow Studio install it.

**Cost.** A SIGKILL to `qa` or Studio itself can't be caught, so its children can still be left behind. The `ps` lookups add a little time to every stop.

## D25. `elementAt` reports the control the mirror outlines (*as built*)

**Problem.** Clicking a text field in the mirror sometimes selected the `Scrollable` that an `EditableText` builds inside itself: a node with no text, key or semantics, and the wrong thing to show or record.

**Choice.** The agent's `elementAt` still builds selector suggestions from the innermost interesting widget under the point, but the node it **reports** climbs past bare controls (interactive, with no text, key, semantics id or label) that cover exactly the visible rect of the nearest enclosing interactive hit. QAFlow Studio's local hover (`elementAtPoint`) ranks by the smallest visible area and keeps the outer node on a tie, so the hover outline and the click agree.

**Why.** The reported element is what the user meant to click, while the suggestions keep their specificity. A nested control with its own key or a smaller rect is still reported as itself.

## Known limitations

- **Release builds can't be driven** (D1); use profile builds.
- **Desktop app windows must stay visible during a run or inspect session.** macOS pauses hidden windows' frames, and the agent answers `not_ready` (`lifecycle: hidden`). Simulator and emulator windows may be hidden; the app itself must be in the foreground on the device.
- **Windows and Linux** are implemented but **unverified**; macOS is the verified platform. A Windows `qa host` has not been tried on a real Windows machine yet (only on loopback on a Mac).
- **Mobile:** simulators and emulators only, launched from source; iOS in debug only; no physical devices; system alerts can't be driven; Android `setOrientation` on an app locked to one orientation costs 10 s per step.
- **One run at a time** in the studio, and a run excludes an inspect session (and the element picker, which uses it).
- **One client per `qa host`** (D23); Studio does not manage the SSH tunnel.
- **Secrets on disk.** Secret values and host tokens are stored in a 0600 JSON file, not the system keychain. They are never written to the project or to step titles, but failure screenshots and element dumps can contain what was typed.
- **Baselines** are per device key: two machines that render differently under the same key need `QA_BASELINE_KEY_SUFFIX`. Renaming a flow file moves its baselines; unused baselines are not deleted.
- **Editor:** `contextAt` does not follow multi-line flow maps; renaming a subflow does not update its callers; Extract does not parameterise values; the Cmd-click outside-root check does not resolve symlinks.
- **Stale subflow warnings.** `flowsReferencing` (the delete warning) finds direct `runFlow` references only, not references nested inside other subflows.
- **A force-killed `qa` or Studio** (SIGKILL) can still leave `flutter run` and the app running (D24).
