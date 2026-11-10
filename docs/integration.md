# Integration and CI

Step-by-step guides for testing your own Flutter app with QAFlow and for running its flows in CI. For every command and option, see the [command reference](commands.md).

## Test your own Flutter app

### 1. Prerequisites

- Flutter 3.47 or later, the version QAFlow is built and tested with (the packages need Dart 3.12). Flutter 3.47 needs macOS 12 or later to build macOS apps.
- A target QAFlow can drive:

  | Target | Status | Notes |
  |---|---|---|
  | macOS desktop | Verified | `flutter create --platforms=macos .` if the app has no macOS folder yet |
  | iOS simulator | Verified | Xcode with a simulator runtime; **debug only** (Flutter refuses profile on a simulator) |
  | Android emulator | Verified | An Android SDK with an AVD (`ANDROID_HOME` or `ANDROID_SDK_ROOT` if not in the default place); debug and profile |
  | Windows, Linux desktop | Written, not yet verified | Linux needs a visible display |

- Release builds cannot be driven: the VM service QAFlow talks through only exists in debug and profile builds.

### 2. Add the agent

```yaml
dependencies:
  qaflow_agent: ^0.1.0
```

or `flutter pub add qaflow_agent`.

It must be a regular dependency, not a dev dependency, because a file in `lib/` imports it. It still stays out of what you ship: `qa` only launches the separate `lib/main_qa.dart` entrypoint, `lib/main.dart` never imports the agent, and `QaAgent.install()` throws when `kReleaseMode` is true.

### 3. Add the QA entrypoint

Create `lib/main_qa.dart`. If `main.dart` does setup before `runApp`, move it into a shared function, so tests start the app the way users do:

```dart
import 'package:flutter/widgets.dart';
import 'package:qaflow_agent/qaflow_agent.dart';

import 'bootstrap.dart';

void main() async {
  QaAgent.install(onReset: clearLocalData); // onReset is optional; it backs clearState
  runApp(QaAgent.wrap(await bootstrap()));
}
```

- **`QaAgent.wrap`** goes around the outermost widget given to `runApp`.
- **`onReset`** should clear whatever your app persists: preferences, databases, files. Between flows the app is restarted, but persisted data survives a restart. Without it, `clearState` and `launchApp: {clearState: true}` fail with `unsupported`.
- The project file's `app.entrypoint` (or `--entrypoint`) points elsewhere if you name it differently.

### 4. Platform setup

- **macOS.** Debug and profile builds use `macos/Runner/DebugProfile.entitlements`. Flutter's default file already has what the VM service needs:

  ```xml
  <key>com.apple.security.network.server</key>
  <true/>
  ```

  Screenshots are transferred inline over the VM service, so the App Sandbox needs nothing more.
- **Android.** Flutter's default `debug` and `profile` manifests already declare `android.permission.INTERNET`, which the VM service needs. Keep it.
- **iOS.** Nothing to add for a simulator.
- **Mobile builds** are launched from source (`app.source`); prebuilt apps are desktop only.

### 5. Give widgets stable ids

Text works with no changes. For anything whose text changes or repeats, add `key: const ValueKey('login')` or `Semantics(identifier: 'login', …)`, and select it with `{id: login}`. Only `ValueKey<String>` keys are recognised.

### 6. Add the project file and flows

A minimal `.qa/project.yaml`:

```yaml
app:
  source: .
flows:
  folders: [.qa/flows]
```

Then add flows to `.qa/flows/` (see the [quick start](../README.md#quick-start) and the [command reference](commands.md)). Put shared subflows in a folder the project doesn't scan, such as `.qa/subflows/`, so they don't also run on their own.

Commit `.qa/` (flows, subflows, baselines) and add `qa-out/` to `.gitignore`. To run the same flows on several targets, keep one project file per target, for example `.qa/project.yaml`, `.qa/project.ios.yaml` (`device: ios:iPhone 17 Pro`) and `.qa/project.android.yaml` (`device: android:<AVD>`), and use tags (`mobile`, `desktop`) with `excludeTags` to keep platform-specific flows apart.

### 7. Run

```bash
dart pub global activate qaflow                  # once; gives `qa` and `qaflow`
qa validate --config .qa/project.yaml            # check flows without launching anything
qa test --config .qa/project.yaml                # run them
qa test --config .qa/project.yaml --device "ios:iPhone 17 Pro"
qa test --config .qa/project.yaml --device android:<AVD name>
```

Or, with `qaflow` in the app's `dev_dependencies`, `dart run qaflow:qa test …` from the app's folder. Run from the app's folder, `--config` can be left out: `qa` uses `./.qa/project.yaml` when it exists.

`qa ping --config .qa/project.yaml` is a quick check that the app launches and the agent answers: it pings the agent, saves one screenshot and stops.

### 8. Screenshot baselines

If your flows use `assertScreenshot`, the first run records baselines under `.qa/baselines/<device key>/` (each step warns `baseline recorded`). Review and commit them. Each machine and OS version has its own device key, so another Mac or OS version records its own set. Once a set is committed, run with `--baselines strict` (or `flows.baselines: strict`) so a missing baseline fails instead of being recorded. Accept an intended change by rerunning with `--baselines update`, or by copying `<name>.actual.png` from the run folder over the baseline.

### Testing a prebuilt build

On desktop you can drive a build instead of building from source. Build it in profile (or debug) mode from the QA entrypoint:

```bash
flutter build macos --profile -t lib/main_qa.dart
```

then point `app.binary` (or `--binary`) at it, with `mode: profile`:

```bash
qa test --config .qa/project.yaml --binary build/macos/Build/Products/Profile/my_app.app --mode profile
```

Release builds are refused, since they have no VM service.

## Run flows in CI

A CI job needs Flutter, the `qa` command and a machine that can show the app: a **macOS machine with a logged-in desktop session** for macOS apps, a simulator for iOS, an emulator for Android.

```bash
dart pub global activate qaflow
export PATH="$PATH:$HOME/.pub-cache/bin"
flutter pub get
flutter build macos --debug -t lib/main_qa.dart    # build first: a cold build can exceed the launch timeout
qa test --config .qa/project.yaml --env PASSWORD="$PASSWORD"
```

- **Exit code:** 0 when every flow passed; flaky counts as passed. 1 for failures, 64 for a usage mistake (see [exit codes](commands.md#the-qa-command-line-tool)).
- **Reports:** publish `qa-out/*/junit.xml` to your CI's test report, and keep the whole `qa-out/` folder as an artifact. Its `report.html` and screenshots work offline. Screenshots are linked from `junit.xml` as `[[ATTACHMENT|<path>]]` lines and from `report.html` by relative path; both are relative to the directory `qa test` ran in, so archive artifacts from that same directory.
- **Secrets:** pass them as `--env NAME=…` or as environment variables of the same name. A secret listed in `flows.secrets` with no value stops the run with exit 64.
- **Build first.** Build the app in a step before `qa test`, so the flows spend their time testing rather than compiling inside the app-start timeout.
- **Keep the window visible.** On macOS a window that is covered, minimised or on another Space stops rendering, and steps fail with `not_ready`. On Linux, give the runner a display the window is actually drawn to (for example `xvfb-run -a`).

### Mobile in CI

- **iOS.** On a macOS runner, pick a simulator the image has, boot it (`xcrun simctl boot <udid>` and `xcrun simctl bootstatus <udid> -b`) before building so it has time to settle, build with `flutter build ios --simulator --debug -t lib/main_qa.dart`, then `qa test --device "ios:<udid>"`. Set `QA_IOS_BOOT_TIMEOUT` (seconds) if a cold boot takes longer than 120 s.
- **Android.** On a Linux runner with KVM, start the emulator with an action such as `reactivecircus/android-emulator-runner` and point `qa` at its serial: `--device android:emulator-5554`. Build the APK first (`flutter build apk --debug -t lib/main_qa.dart`). Set `QA_ANDROID_BOOT_TIMEOUT` (seconds) if a boot takes longer than 180 s. A cold boot (`-no-snapshot`) is more reliable than restoring a cached snapshot, which has been seen to leave a software-GL emulator with a zero-size app window. Hosted runners may also need disk space freed first.

### Screenshot baselines in CI

A hosted runner renders fonts differently from your Mac but can have the same device key. Set `QA_BASELINE_KEY_SUFFIX=ci` so CI reads and writes its own set (`macos-<version>-ci`, `ios-<simulator>-<OS>-ci`, …). Then:

1. Run with `--baselines record` until a CI set is committed, and upload `.qa/baselines/*-ci/` with the reports. `actions/upload-artifact@v4` skips paths under a dot folder such as `.qa/` unless you set `include-hidden-files: true`.
2. Download the artifact of a passing run, look through the recorded images, and commit the `*-ci` folders into `.qa/baselines/`.
3. Switch CI to `--baselines strict`, so a missing or changed screen fails the job.

When the runner image changes its simulator or OS version, the key changes too; record and commit that set the same way.

## Run on another machine

When the app has to run somewhere other than where `qa` runs (a Windows desktop app driven from a Mac, a Mac with simulators driven from a Linux CI box), start `qa host` on the machine that runs the app and reach it through an SSH tunnel. Flows, reports and baselines stay on your machine. See [Remote hosts](remote-hosts.md).
