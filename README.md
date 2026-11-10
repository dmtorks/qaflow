# QAFlow

End-to-end QA for Flutter apps. You write Maestro-style YAML flows ("tap
Login, type a password, check the welcome text"); the `qa` command launches
your app, performs the steps through the real widget tree, and writes
`results.json`, `junit.xml` and a static `report.html`, with screenshots,
element dumps and logs for every failure.

- **Targets:** Flutter desktop apps on macOS, Windows and Linux (from source
  or a prebuilt debug or profile build), and, from source, apps on iOS
  simulators and Android emulators, booted on demand.
- **Screenshot assertions** against per-device baselines committed with your
  flows.
- **Remote hosts:** run the app on another machine through `qa host` and an
  SSH tunnel.
- **CI-friendly:** exit codes, JUnit output and a report that works offline.

## How it works

Your app gets a second entrypoint, `lib/main_qa.dart`, that installs
`qaflow_agent`. The agent registers `ext.qa.*` service extensions on the Dart
VM service, the debugging connection every debug and profile build already
opens. `qa` launches the app (with `flutter run`, a prebuilt binary, or
through a `qa host`), connects to the VM service, and turns each flow step
into calls such as `ext.qa.tap`. Inside the app the agent finds the widget
by walking the element tree, checks with a hit test that a real tap would
reach it, and feeds synthetic pointer, key and text events into Flutter's
own bindings, so your widgets see ordinary input. Screenshots come from a
`RepaintBoundary` around your app.

Release builds cannot be driven: they have no VM service, and the agent
refuses to install in release mode.

## Packages

| Package | What it is | You add it to |
|---|---|---|
| [`qaflow_agent`](https://pub.dev/packages/qaflow_agent) | The in-app agent (Flutter) | The app under test |
| [`qaflow`](https://pub.dev/packages/qaflow) | The engine and the `qa` command (also installed as `qaflow`); pure Dart | Your machine, or the app's `dev_dependencies` |
| [`qaflow_protocol`](https://pub.dev/packages/qaflow_protocol) | Wire types shared by the two; pure Dart | Nothing: the others pull it in |

The three packages share one version. QAFlow is built and tested with
Flutter 3.47 (the packages need Dart 3.12 or later).

## Install

**1. Add the agent to the app under test.**

```yaml
dependencies:
  qaflow_agent: ^0.1.0
```

or `flutter pub add qaflow_agent`. It is a regular dependency, not a dev
dependency, because a file in `lib/` imports it.

**2. Add a QA entrypoint**, `lib/main_qa.dart`, next to your normal
`lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

import 'main.dart';

void main() {
  QaAgent.install();
  runApp(QaAgent.wrap(const MyApp()));
}
```

`QaAgent.wrap` puts your app inside the `RepaintBoundary` screenshots are
taken from. Pass `onReset:` to `QaAgent.install` to clear your app's
persisted state when a flow asks for a clean start (`clearState`).

The agent stays out of what you ship: `qa` launches `lib/main_qa.dart`, your
`lib/main.dart` never imports the agent, and `QaAgent.install()` throws in
release mode.

**3. Install the CLI.**

```sh
dart pub global activate qaflow   # gives both `qa` and `qaflow`
qa --help
```

Or add `qaflow` to the app's `dev_dependencies` and run it as
`dart run qaflow:qa`.

## Quick start

In your app's folder, create `.qa/project.yaml`:

```yaml
app:
  source: .
flows:
  folders: [.qa/flows]
```

and a first flow, `.qa/flows/smoke.yaml`:

```yaml
name: The home page shows its title
---
- launchApp
- assertVisible: Flutter Demo Home Page
- takeScreenshot: home
```

Check the flows without launching anything, then run them:

```sh
qa validate --config .qa/project.yaml
qa test --config .qa/project.yaml
```

With no `--device`, the app runs on this computer's desktop. `qa test`
prints each step as it runs, then the paths of the report and the JUnit
file. Each run gets its own folder, `qa-out/<run id>/`, where the run id is
a UTC timestamp:

```
results.json                              the whole run, machine-readable
junit.xml                                 one testcase per flow
report.html                               static, no JavaScript
flows/<flow>/screenshots/*.png            screenshots
flows/<flow>/elements-<step>.json         every element on screen, for a failed step
```

Commit `.qa/` and add `qa-out/` to `.gitignore`. A flow is a header, a
`---` line, then a list of commands:

```yaml
name: Log in
tags: [login]
---
- launchApp
- tapOn: {id: email}
- inputText: test@example.com
- tapOn: {id: password}
- inputText: ${PASSWORD}
- tapOn: Sign in
- assertVisible: Welcome
```

Commands include `tapOn`, `inputText`, `pressKey`, `assertVisible`,
`scrollUntilVisible`, `swipe`, `takeScreenshot`, `assertScreenshot`,
`runFlow` and `repeat`; selectors match by text (literal or a regular
expression), `id` (a `ValueKey<String>` or a Semantics identifier), `type`,
`index`, `enabled` and `childOf`. The [command reference](docs/commands.md)
has every command, option and default.

## Targets

`app.device` in the project file, or `--device` on the command line:

| Target | Device id | Notes |
|---|---|---|
| macOS, Windows, Linux desktop | `macos`, `windows`, `linux` | The default is this computer. macOS is verified; Windows and Linux are written but not yet verified |
| iOS simulator | `ios:<name or UDID>`, e.g. `ios:iPhone 17 Pro` | Debug only. Needs macOS and Xcode |
| Android emulator | `android:<AVD name>` or `android:emulator-5554` | Debug and profile. Needs the Android SDK |
| Headless | `flutter-tester` | A fast lane for CI, with no OS window |

`qa` boots a shut-down simulator or AVD and leaves it running afterwards.
On mobile the agent sends touch input, so `swipe` scrolls lists and `hover`
is unsupported; `back`, `hideKeyboard`, `setOrientation` and `openLink`
drive the device. Mobile apps are launched from source; a prebuilt binary
(`app.binary`, `--binary`) is desktop only.

```sh
qa test --config .qa/project.yaml --device "ios:iPhone 17 Pro"
qa test --config .qa/project.yaml --device android:emulator-5554
```

Keep the app window visible during a desktop run: macOS stops rendering a
window that is minimised, fully covered or on another Space, and steps then
fail with `not_ready`.

## Screenshot assertions

`assertScreenshot` compares the screen with a baseline PNG stored in
`.qa/baselines/<device key>/<flow>/<name>.png`:

```yaml
- assertVisible: Items
- assertScreenshot:
    name: list
    threshold: 0.5        # largest % of differing pixels that still passes; default 0.1
    ignore:
      - id: clock         # areas blanked in both images before comparing
```

The device key is the platform and OS version on desktop (`macos-27.0`) and
platform, device name and OS version on a simulator or emulator, so each
device keeps its own set. `--baselines` (or `flows.baselines`) picks what
happens:

| Mode | Baseline missing | Baseline present |
|---|---|---|
| `record` (default) | Written; the step warns `baseline recorded` | Compared |
| `strict` | The step fails | Compared |
| `update` | Written | Overwritten |

A failed comparison keeps `<name>.actual.png`, `<name>.baseline.png` and a
`<name>.diff.png` with the differing pixels in red, and `report.html` shows
them side by side. Review and commit the recorded baselines, then run with
`--baselines strict` in CI.

## Remote hosts

`qa` on one machine can run flows against an app on another, for example a
Windows desktop app on a cloud VM driven from a Mac. The other machine runs
`qa host`, which listens on `127.0.0.1` only; you reach it through an SSH
tunnel and a token:

```sh
qa host                                    # on the machine that runs the app; prints a token once
ssh -N -L 7777:127.0.0.1:7777 me@qa-host   # on your machine
export QA_HOST_TOKEN=<the token>
qa test --config .qa/project.yaml --host ws://127.0.0.1:7777 --host-project 'C:\src\myapp'
```

Flows, reports and baselines stay on your machine; the host only builds and
runs the app. See [Remote hosts](docs/remote-hosts.md).

## QAFlow Studio

QAFlow Studio is a macOS app over the same engine: open a project, write
flows with suggestions and a picker that reads the running app, record flows
by clicking, watch runs live, and review, compare and accept screenshots
from past runs. It is a separate download and does not need the packages
installed. It isn't publicly available yet.

## Documentation

- [Command reference](docs/commands.md): every flow command, selector, key
  name and `qa` option.
- [Integration and CI](docs/integration.md): testing your own app step by
  step, and running flows in CI.
- [Troubleshooting](docs/troubleshooting.md): messages, causes and fixes.
- [Remote hosts](docs/remote-hosts.md): setting up and using `qa host`.
- [Changelog](CHANGELOG.md).

## Reporting issues

Report bugs and request features in this repository's
[Issues](https://github.com/dmtorks/qaflow/issues). For a bug, include the
qaflow and Flutter versions, the platform and device, your `.qa/project.yaml`
and the flow (with secret values removed), and the report or console output.
[Troubleshooting](docs/troubleshooting.md#collecting-information-for-a-bug-report)
lists what helps most.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
