# 9. Troubleshooting

Problems are grouped by when they happen, then by feature: screenshots, QAFlow Studio, the flow editor, remote hosts and leftover processes. Each entry gives the message you see (text in `code` is quoted from the toolkit), what causes it, and the fix.

**Where to look first:**

- **The step's error:** shown in the Run and Runs screens, the console and `report.html`.
- **The failed step's files:**
  - `failure-<step>.png`, what was on screen;
  - `elements-<step>.json`, every element the app had, with its text, id, type, size and whether it was visible.
- **The app's output:** the Run screen's log panel (filterable), `qa test --verbose`, or the log tail attached to a failed step.

## Before anything runs

| Message | Cause | Fix |
|---|---|---|
| `could not find flutter; choose it in QAFlow Studio settings or pass --flutter` | Apps started from the Dock don't inherit your terminal's PATH. The toolkit looks in `FLUTTER_ROOT`, fvm, PATH and your login shell | QAFlow Studio: Studio settings (⌘,) → Choose… the `flutter` executable. CLI: `--flutter /path/to/flutter` |
| `file:line:col: unknown command tapon (did you mean tapOn?)` | A typo; names are case-sensitive | Use the suggested name |
| `X is not supported by QAFlow` | A Maestro command the toolkit does not implement (`setLocation`, `runScript`, `assertTrue`, …) | Remove it, or replace it with what the app can do through the agent |
| `unknown device "iPhone 17 Pro"; use macos, … (e.g. "ios:iPhone 17 Pro")` | A device name without its platform prefix | Prefix it: `ios:<simulator name or UDID>` or `android:<AVD name or emulator serial>` |
| `profile mode is not supported on iOS simulators; use debug` | `mode: profile` (or `--mode profile`) with an `ios:` device. Flutter cannot run profile builds on a simulator | Use debug for iOS. Android emulators run profile |
| `prebuilt apps are not supported on mobile devices yet; use app.source` | `binary` with an `ios:` or `android:` device | Launch from source |
| `selector field above is not supported` | Relative-position selectors don't exist here | Use `childOf`, an `id`, or `index` |
| `JavaScript expressions are not supported: ${…}` | Only `${NAME}` is substituted | Compute the value outside the flow and pass it with `--env` |
| `runFlow cycle: a.yaml -> b.yaml -> a.yaml` | Subflows call each other | Break the loop |
| `runFlow file not found` | Subflow paths are relative to the *calling* file | Fix the path relative to that file |
| `qa: no flows to run` | Tag filters excluded everything | Check `--include-tags`/`--exclude-tags` or `flows.includeTags`/`excludeTags` |
| Exit 64 naming missing secrets | A secret listed in `flows.secrets` has no value | `--env NAME=…`, or set an environment variable with that name; QAFlow Studio asks for it |

## Launching and connecting

| Message | Cause | Fix |
|---|---|---|
| `flutter run exited with code N before the app started` with the last output | The build failed | Read the quoted output. It's the compiler's or Xcode's error. Build the app once with `flutter run -d macos -t lib/main_qa.dart` to see it in full |
| `the app process exited with code N before the VM service connected` | The app crashed at startup. On macOS the quoted output is often a `dyld` message about a missing framework | Fix the crash; for a prebuilt app, rebuild it |
| `could not connect to the VM service … release builds have no VM service and cannot be driven` | A release build, or a crash before the VM service opened | Use a debug or profile build. QAFlow Studio and `qa` now refuse release `.app` bundles straight away |
| "This build may not include the QA agent" (QAFlow Studio) or `no isolate exposes ext.qa.ping` | The build doesn't start from `lib/main_qa.dart`, or `main_qa.dart` doesn't call `QaAgent.install()` | Rebuild with `-t lib/main_qa.dart`, and check the entrypoint in Project settings |
| `agent protocol vX does not match driver protocol vY` | The app was built against a different toolkit version than the one running | Update the app's `qaflow_agent` dependency to the same commit or tag as QAFlow Studio and the CLI |
| The app starts but nothing happens, then a timeout | macOS asked something (permissions, a dialog) or the window opened off-screen | Bring the app window forward and answer the prompt. Native dialogs can't be driven, so add a test hook in `main_qa.dart` to skip them |
| macOS: "QAFlow Studio can't be opened" / "is damaged" | An ad-hoc signed build from another Mac, quarantined by Gatekeeper | Approve it once (System Settings → Privacy & Security → Open Anyway, or `xattr -dr com.apple.quarantine "/Applications/QAFlow Studio.app"`). "Damaged" on a build you made yourself means its signature is broken: rebuild with `tool/package_studio.dart` |

## Simulators and emulators

| Message | Cause | Fix |
|---|---|---|
| `no iOS simulator named "…"; available: …` | No available simulator has that name (names are exact, including spaces) | Pick one from the list, from `xcrun simctl list devices available`, or use its UDID |
| `iOS simulators need macOS` / `Xcode command line tools not found (xcrun)` | iOS targets on another OS, or Xcode is not installed or selected | Run on a Mac with Xcode and an iOS simulator runtime; `xcode-select -p` should print Xcode's path |
| `no Android emulator (AVD) named "…"; available: …` | No AVD has that name | Use a name from `emulator -list-avds`, or create the AVD in Android Studio's Device Manager |
| `Android SDK not found (set ANDROID_HOME)` | `adb` and `emulator` were not found in `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the SDK manager's default folder or `PATH` | Set `ANDROID_HOME` to the SDK folder, with the `emulator` and `platform-tools` packages installed |
| `emulator-5554 is not running` | An `android:emulator-<port>` serial that `adb devices` does not list as a running device | Start the emulator first, or name the AVD instead so `qa` boots it |
| `booting … did not finish within 180 s` (or 120 s for iOS) | A cold boot that was too slow, typically on CI or the first boot of a new AVD | Raise `QA_ANDROID_BOOT_TIMEOUT` (seconds) for Android or `QA_IOS_BOOT_TIMEOUT` for iOS, or boot the device once by hand. The device keeps booting and the next run reuses it |
| `expected an iOS app but the agent reports android` (or the reverse) | `flutter run -d` reached a different device than the one resolved, for example two devices sharing a name | Use the UDID or emulator serial |
| An Android run fails on its first flow right after `qa` booted the emulator, with the app restarted under it | Android restarts the activity when the emulated SIM arrives a few seconds after boot. `qa` waits up to 30 s for it; an image without a SIM uses up that wait | Boot the emulator before the run, or re-run (the device is already up the second time) |
| An `openLink` step on iOS leaves a system "Open in …?" alert and the next step fails | iOS asks before opening a custom-scheme link, and the agent cannot tap system alerts | Keep custom-scheme deep-link flows Android-only (`runFlow: {when: {platform: android}}`), as the demo's `deep_link.yaml` does |
| `hover needs a mouse; this app runs on a touch platform` (`unsupported`) | `hover` on iOS or Android | Tag the flow (the demo tags `tooltip.yaml` `desktop`) and exclude it from the mobile project file, or use `longPressOn` for tooltips |
| An orientation flow on iOS fails its first portrait check, and the app starts in landscape | The simulator was left in landscape (for example by an earlier session); a fresh launch follows the simulator's orientation, and `qa` only restores portrait after a flow that ran `setOrientation` | Rotate the simulator back to portrait (Simulator → Device → Rotate), or start such flows with `setOrientation: PORTRAIT` |
| The app is in the background on the device (`not_ready`) | After `openLink` handed the link to another app, or someone pressed Home | Bring the app back to the foreground; the Simulator and emulator windows themselves may be hidden |
| An Android emulator never finishes booting on a cloud VM, or `emulator` says acceleration is unavailable | The x86 emulator needs hardware virtualization. On a cloud VM that means **nested virtualization** (WHPX/Hyper-V on Windows, KVM on Linux), which many instance types lack | Use an instance type that offers nested virtualization (on AWS a metal instance; on Azure Dv3/Ev3 or later sizes), or attach a real device to that machine (physical devices are not supported by `qa` yet). On a Linux CI runner enable KVM, as `e2e.yml` does |
| `booting … did not finish` on the first run of a new simulator runtime or AVD | The first boot of a new image is much slower than later ones | Boot it once by hand (Simulator, or `emulator -avd <name>`), then run again; raise the boot timeout for CI |
| A flow that passes on macOS fails on a phone with `off_screen` or `not_found` | Phone screens are smaller, and a mobile layout may hide or reorder widgets | Scroll explicitly (`scrollUntilVisible`); keep desktop-only flows out of the mobile project file with tags (the demo's `project.yaml` excludes `mobile`, and its mobile files exclude `desktop`) |

## During a run

| Message (code) | Cause | Fix |
|---|---|---|
| `nothing matches …` (`not_found`) | The element doesn't exist yet, the text differs (exact match after trimming), or it's in a list row that hasn't been built | Check `elements-<step>.json` for the real text and ids. For long lists use `scrollUntilVisible`. Prefer an `id` over text |
| `N widgets match …; add index or narrow the selector` (`ambiguous`) | Several elements match | Add an `id`, use `childOf: {id: …}`, or `index` |
| `… is covered at x,y by Widget` (`obscured`) | Something is on top: a dialog, a scrim, a snackbar, an overlay | Close or wait for whatever covers it (`assertNotVisible`, `waitForAnimationToEnd`). The named widget tells you what's covering it |
| `… is disabled` (`not_ready`) | The control exists but is disabled | Fill in what enables it first. To check the state itself, use `assertVisible: {id: …, enabled: false}` |
| `off_screen` | The element exists but is scrolled out of its list or out of the window | `scrollUntilVisible`, or make the window larger. The toolkit never scrolls on its own |
| `no text field has focus; pass a selector or tap a field first` | `inputText` or `eraseText` with no field focused | `tapOn` the field first, or use `setText` with `element:` |
| `the app is not rendering frames (lifecycle: hidden); … Keep the app window visible during a run.` | The app's window is minimised, fully covered, or on another Space or desktop. macOS then stops drawing it | Keep the window visible. Don't switch Spaces or run full-screen apps over it during a run |
| `the app registered no reset hook; pass onReset to QaAgent.install` (`unsupported`) | `clearState` with no hook | Add `onReset:` to `QaAgent.install` in `main_qa.dart`, or remove `clearState` |
| `the app is not running; add launchApp after stopApp` | A step after `stopApp` | Add `launchApp` |
| `undefined variable NAME` | No value anywhere for `${NAME}` | Define it in the flow's `env:`, the project's flow variables, or `--env` |
| `… not visible after scrolling down for 20000 ms` | `scrollUntilVisible` didn't find it | Check the `direction`, the text, and `visibilityPercentage` (100 needs the *whole* element visible; try 50). Name the right list with `scrollable:` |
| `repeat limit reached after 100 iterations` | A `repeat: {while: …}` whose condition never became false | Add `times:` or fix the condition |
| `the app did not answer ext.qa.… within N s` | The app's UI thread is frozen (an infinite loop, a deadlock, or paused in a debugger) | Ends the run with the remaining flows "not run". Find the hang in the app; the log tail often shows it |
| A step passes but the next fails intermittently | Timing: the app was still animating or loading | Assert on what you're waiting for before acting (`assertVisible: Done`), or use `extendedWaitUntil` with a longer timeout. Health dots and the Flaky badge show which flows are unstable |
| A tap does nothing on desktop list items | A mouse *drag* doesn't scroll lists on desktop | Use `scroll` or `scrollUntilVisible`, not `swipe` (on iOS and Android `swipe` does scroll) |
| Typed text is wrong or doubled | An input formatter changed it, or the selector matched the field by its old text | Formatters run as for a user, so assert the formatted result. Target fields by `id`, not by their contents |

## Screenshot assertions and baselines

Baselines live in `<app root>/.qa/baselines/<device key>/<flow file slug>/<name>.png` (chapter 3; chapter 5, D18). The run folder keeps `<name>.actual.png`, `<name>.baseline.png` and `<name>.diff.png` for each comparison.

| Message (code) | Cause | Fix |
|---|---|---|
| `size <w>×<h> differs from baseline <w>×<h>` (`screenshot_mismatch`) | The baseline was recorded on a different screen scale or window size under the same device key (two Macs on the same macOS version both use `macos-27.0`, one on a Retina display), or the window was resized | Check the screen scale and keep the same window size. A different simulator or OS version gets its own key and records its own set; for a machine that renders differently under the same key (a CI runner) set `QA_BASELINE_KEY_SUFFIX`. If the new size is intended, run once with `--baselines update` or Accept the actual image in QAFlow Studio |
| `<p>% of pixels differ (threshold <t>%)` (`screenshot_mismatch`) and the diff shows real changes | The screen changed | If the change is intended, Accept the actual image in QAFlow Studio or run with `--baselines update`, and commit the new baseline |
| `assertScreenshot` fails on some runs and passes on others | A clock, counter, caret, animation or loading state is in the shot | `ignore` the changing widgets; assert on what you wait for (`assertVisible`) before the screenshot so the screen has settled; raise `threshold` slightly only for small, known noise. The red pixels in `<name>.diff.png` show what moved |
| `no baseline for "<name>" on <device key> (run with --baselines record or update)` | Strict mode on a device or key with no baseline yet (a new simulator, an OS upgrade, including macOS on the desktop, or `QA_BASELINE_KEY_SUFFIX`) | Run once with `--baselines record`, review and commit the files under `.qa/baselines/<device key>/` |
| `assertScreenshot needs a project (pass --config or --project) to know where baselines live` (`bad_request`) | `qa test` with `--binary` and no project file, so there is no app root for `.qa/baselines` | Pass `--config <app>/.qa/project.yaml` or `--project <app>` |
| Every `assertScreenshot` step warns `baseline recorded` | `record` mode (the default) with no baseline for this device key yet: a new machine, simulator, OS version, or a renamed or moved flow file | Expected on the first run. Review the new files under `.qa/baselines/<device key>/` and commit them; later runs compare against them |
| The baselines folder fills with a new `macos-<version>` set after an OS update | Desktop keys carry the OS version (`macos-27.0`), so an upgrade starts a new set, as on simulators | Review and commit the new set; delete the old one when no machine uses that version any more |
| CI and a developer machine keep overwriting each other's baselines | They render differently but share a device key | Set `QA_BASELINE_KEY_SUFFIX` on one of them (CI uses `ci`), so it records under its own key |
| Accept as baseline is greyed out (QAFlow Studio) | The run belongs to another project (or none is open), the baseline changed on disk since the run, or the run's paths point outside `.qa/baselines` or the run folder | The tooltip says which. Open the run's own project; for a baseline that changed since, run the flow again and accept from the new run |

## QAFlow Studio

| Symptom | Cause | Fix |
|---|---|---|
| Run flow is greyed out | Another run or an inspect session is active, the project file is invalid, Flutter wasn't found, the flow has a parse error, or the flow has unsaved edits | The button's tooltip says which. Save the editor (Run flow runs the file on disk, not unsaved text) |
| Inspect shows an old picture | The mirror only refreshes after an action and on Refresh | Click Refresh. If a banner says the window is hidden, bring the app forward |
| "Recording stopped: … was deleted" or "… has a problem" | The flow file was deleted, or no longer parses | Restore or fix the file, then Record into this flow again |
| "Recording stopped: can't append to …" | The file is valid but laid out so a plain appended line would break it (an indented list, `[launchApp]` flow style, `...` at the end). The last action ran in the app but wasn't written | Record into a new flow, or reformat the file as a plain block list |
| Undo last step clears instead of undoing | The file was edited outside the recorder since its last write | Undo only reverts the studio's own last write; edit the file directly |
| A dialog says the file changed on disk while you have edits | Another editor saved the file | Reload (lose your edits) or Keep my edits (save over it later) |
| A simulator or emulator booted outside the studio is missing from the Target picker | The device list is loaded once | Press Refresh beside the device field in Project settings |
| Profile is greyed out in Project settings, or missing from the Target picker | An iOS simulator is selected; Flutter runs only debug there | Use debug, or pick an Android emulator or this computer |
| "Booting …" stays up for minutes | A cold emulator boot | Wait, or Stop run (the device keeps booting and the next run reuses it) |
| "Looking for Flutter…" never finishes | The login-shell lookup is slow or hangs | Choose the `flutter` path in Studio settings |
| No notification when a run finishes | QAFlow Studio was in front (notifications only fire in the background), or permission was denied | System Settings → Notifications → QAFlow Studio |
| The window opens off-screen or too large | A saved position from a display that's gone | The studio moves it on-screen at launch. To forget the saved position, quit QAFlow Studio and run `defaults delete dev.flutterqa.studio "NSWindow Frame QAStudioMainWindow"` |
| Run flow says `This project runs on the QA host at <url>. Add that host and its token in Studio settings → Remote hosts.` | The project's `host:` names a URL this studio has no entry (or no token) for | Studio settings → Remote hosts → Add host, with that URL and the token `qa host` printed |
| The device picker reads `Save to list the host's devices` (or `… this computer's devices`) and lists nothing | Run on was changed but not saved; listings follow the saved file | Save, then pick the device |
| `This path is for the other machine; update it` under the source or build field | Run on moved the project back to This computer, and the path is a host path (a Windows path on a Mac, for example) | Change it to the app's path on this machine |
| QAFlow Studio was killed or crashed during a run, and the app under test is still open | A force-kill or crash can't run the studio's shutdown | Stop the leftovers by hand; see "Leftover processes" below |

## The flow editor

| Symptom | Cause | Fix |
|---|---|---|
| Ctrl+Space switches the keyboard input source instead of opening suggestions (macOS) | macOS uses Ctrl+Space for "Select the previous input source" when more than one input source is enabled | Turn that shortcut off in System Settings → Keyboard → Keyboard Shortcuts → Input Sources, or just type: suggestions open as you type a command, key or value |
| No suggestions appear on an empty line or right after `key:` | Typing alone stays quiet on an empty key, and an empty value opens only after the space that follows `:` | Press Ctrl+Space, or type a space after the colon |
| Ctrl+Space shows "No suggestions here" | Nothing applies at the caret: a comment, a value with no known values, or a key the schema doesn't know | Check the indentation: the editor works out the enclosing command from it. Hover the command for its doc |
| No element texts or ids are suggested, and the footer line is missing | No inspect session ran for this project, and no run has element snapshots. Snapshots (`elements-<step>.json`) are written only for failed steps | Open Inspect & record and start the app once (its elements are kept after you stop), or run a flow that fails |
| Element suggestions are out of date | The footer names the source: "the latest run (<time>)" or "the last Inspect & record session" | Start Inspect & record on the current build; the live app always wins |
| A `runFlow` path is not suggested | The list holds the `.yaml`/`.yml` files under `.qa/` (any depth), as paths relative to the open file; `project.yaml`, `project.*.yaml` and `config.yaml` at the `.qa` root are skipped. It is refreshed when the flow catalog changes | Keep subflows under `.qa/` (for example `.qa/subflows`); type the path by hand for a file elsewhere |
| A key that `qa` accepts is not suggested, or a suggested key is rejected | Suggestions come from `FlowSchema`, which agreement tests keep equal to the parser. A mismatch means one changed without the other | Report it; `packages/qaflow/test/flow_schema_test.dart` should catch it |
| ⌘-click on a `runFlow` path moves the caret instead of opening it | The underline had not appeared yet (the mouse had not rested on the path with ⌘ held) | Hold ⌘ (Ctrl elsewhere) with the mouse on the path until it is underlined, then click |
| `<path> is a folder, not a flow file`, or a path outside the app is refused | ⌘-click opens only flow files inside the app root | Point `runFlow` at a `.yaml` file inside the project |
| Extract to subflow is greyed out with "Select whole steps in one list" | The selection crosses lists, touches the header or `---`, or mixes nesting levels | Select whole sibling steps in the body or in one `commands:` list |
| "Created <path>, but the flow changed meanwhile; the steps were not replaced" | The text changed while the Extract dialog was open | The subflow file exists; replace the steps with `- runFlow: <path>` by hand, or delete the file and extract again |
| Pick from app says "The app isn't running" with Start app greyed out | Another blocker applies: a run is active, or Flutter was not found | The button's tooltip says which |

## Remote hosts

A remote host is a `qa host` on another machine, reached through an SSH tunnel ([chapter 11](11-remote-hosts.md)).

| Message | Cause | Fix |
|---|---|---|
| `Can't reach the QA host at ws://127.0.0.1:7777. Is the SSH tunnel open?` | The tunnel is not running, forwards a different port, or `qa host` is not running on the other machine | Start the tunnel (`ssh -N -L 7777:127.0.0.1:7777 <user>@<host>`) and check `qa host` printed `QA host listening on 127.0.0.1:7777`. In Studio, Test connection, then Retry |
| `The QA host refused the token` | The token doesn't match the host's token file, for example after the file was recreated | Copy the token from the host's token file (`~/.qa/host-token`, or `%USERPROFILE%\.qa\host-token`) into `QA_HOST_TOKEN` or Studio settings → Remote hosts → Edit |
| `Set QA_HOST_TOKEN to the token qa host printed` | A `qa` run with a `host:` and no token | Export `QA_HOST_TOKEN`. Studio passes its stored token instead |
| `QA host is in use by another client` | The host serves one client at a time, and another `qa` or Studio is connected (possibly your own Studio while a CLI run starts) | Finish or stop the other client. A client that dropped releases the host once its connection closes; its apps keep running for 10 s in case it reconnects |
| `The QA host is in use by this studio's run or inspect session. Its devices show once that ends.` (device picker) | This studio holds the host for a run or inspect session and has no cached device list yet | Wait for the session to end, or stop it |
| `Lost the connection to the QA host at <url>.` | The tunnel or the host went away during a run | Reopen the tunnel and press Retry. The host stops the dropped client's apps after its 10 s grace |
| `QA host speaks protocol N; this qa speaks M. Update qa on both machines.` | The two machines run different toolkit versions | Check out the same commit on both |
| `the host token is never read from the project file; set QA_HOST_TOKEN instead` | `project.yaml` has `host: {token: …}` | Remove the key; keep the token in `QA_HOST_TOKEN` or Studio settings |
| `qa: could not listen on 127.0.0.1:7777: …` | Another process (or another `qa host`) uses the port | Stop it, or start with `--port <other>` and tunnel that port |
| A Windows app starts on the host but has no window, and steps time out | `qa host` was started from an SSH session. On Windows such processes run without a desktop | Start `qa host` from a terminal inside the logged-in Remote Desktop session (or a scheduled task set to run only when the user is logged on) |
| `the app is not rendering frames (lifecycle: hidden)` on the host, after closing Remote Desktop | Disconnecting RDP stops the session's desktop from rendering | Keep the RDP window open (minimised is fine), or before disconnecting run `tscon %sessionname% /dest:console` in the session so the desktop keeps rendering |
| `lifecycle: hidden` on a Mac host | As locally: the app window is minimised, covered or on another Space on the host | Keep the app's window visible on the host's screen |
| The app fails to build on the host: a path not found | `app.source`/`app.binary` are host paths, resolved against `host.project` there; the project folder or checkout is wrong | Check **Project folder on the host** and that the host has the app's source at that path (Studio does not sync source) |
| Devices listed are this computer's, not the host's | The `host:` change is not saved, or the project has no `host:` | Save Project settings; the picker header reads `On <host name>` for a hosted project |

## Leftover processes

`qa` and QAFlow Studio stop the app under test, with every process `flutter run` started, when they finish, when you press Stop, when you quit, and on SIGINT or SIGTERM (chapter 5, D24). A second Ctrl-C kills the tracked processes at once and exits. A SIGKILL (`kill -9`, a crash, Force Quit) can't be caught, so the app can be left behind.

| Symptom | Cause | Fix |
|---|---|---|
| The demo app (or your app) is still open after `qa` or Studio ended | The runner was force-killed or crashed | Find the processes: `ps -A -o pid,ppid,command \| grep -E 'flutter_tools\|main_qa\|<your app>'`, then `kill <pid>` (`taskkill /PID <pid> /T /F` on Windows). Quitting the app normally also works |
| The next run fails to start, or two copies of the app are open | A leftover `flutter run` holds the build folder or the device | Kill the leftovers as above, then run again |
| `qa` takes a few seconds to exit after Ctrl-C | It is stopping the session and waiting up to 3 s for each process tree to exit before SIGKILL | Wait, or press Ctrl-C again to kill at once |
| A remote host's apps keep running after the client dropped | The host keeps a dropped client's apps for 10 s, in case it reconnects | They are stopped after the grace period |

## Collecting information for a bug report

Include:

- **the run folder**, `qa-out/<run id>/` (zip it): it has the reports, screenshots, element dumps and log tails;
- **the flow file** and `.qa/project.yaml`, with secret values removed;
- **versions:** `flutter --version` and the toolkit commit, which is in QAFlow Studio's `READ ME FIRST.txt` or from `git rev-parse HEAD`;
- **the output of `dart run qaflow:qa test … --verbose`**, and for a remote host, what `qa host` printed (without the token).

Run folders can contain typed secret values in screenshots and element dumps, so check them before sharing.
