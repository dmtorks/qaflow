# 10. Security model

What the toolkit protects, what it deliberately doesn't, and what to watch for when you use it. It is a **development and CI tool**: it assumes the machines it runs on and the flows it runs are trusted. The one place it crosses a machine boundary, a remote `qa host`, has its own threat model in 10.2.

## 10.1 What is protected

### Test hooks never ship

- **Separate entrypoint.** The agent is only imported from `lib/main_qa.dart`. A normal `flutter build` compiles `lib/main.dart`, which never references it, so release apps contain no test hooks (chapter 1.4.1).
- **Release guard.** `QaAgent.install()` throws in release mode, in case `main_qa.dart` is ever built that way.
- **Engine refusal.** Release builds never open a Dart VM service, so there's nothing to connect to anyway.
- **Early refusal.** `qa` and QAFlow Studio inspect a prebuilt macOS `.app` before launching it and refuse a release build (chapter 2.1).

### Secrets stay out of the repository

- **Names only in the project file.** `flows.secrets` lists names. Giving a secret a value in `flows.env` is a project-file error.
- **Values stay on the machine:** `--env`, an environment variable of the same name, or QAFlow Studio's per-machine store.
- **Titles stay unexpanded.** Step titles are never substituted, so reports, JUnit and the console show `inputText "${PASSWORD}"`, not the value.
- **Obscured fields report no text.** A password field's contents never appear in element snapshots: not in `elements-<step>.json` failure dumps, the inspector, or text selectors.
- **No host token in the project file.** A `token:` key under `host:` is an error (10.2).

### QAFlow Studio's own files

- **Owner-only settings.** `settings.json` (recent projects, the Flutter path, stored secret values, remote host tokens) is written owner-only (mode 0600) through a temporary file and a rename. The `.bak` copy made when the file can't be parsed gets the same treatment.
- **Untrusted run artifacts.** Run folders can come from anywhere (a teammate, CI, a hand edit), so `results.json` is treated as untrusted. QAFlow Studio refuses to open or render any artifact path that is absolute or escapes the run folder (`../`), and a screenshot comparison's baseline must lie inside the project's baselines folder. Such artifacts are only named.

### Files the runner writes

- **Contained screenshot names.** A `takeScreenshot` name is made filename-safe, and a name that would still escape the run's screenshot folder fails the step.
- **Safe baseline names and keys.** A baseline name may use only letters, digits, `.`, `-` and `_`. Device keys and the `QA_BASELINE_KEY_SUFFIX` suffix are cleaned the same way, with leading and trailing dots dropped, so neither can name a folder outside `.qa/baselines` (chapter 2.1, Devices). Baselines are written through a temporary file and a rename.

### Process cleanup

A test tool that leaves apps running wastes resources and can hold files, ports or a device. Since a launched app also exposes a VM service (10.3), an app left running after a test also leaves that service open.

- **Whole trees are stopped.** Stopping an app kills `flutter run` and everything under it, including an app that `flutter run` itself left behind, with SIGTERM, then SIGKILL after 3 s (`taskkill /T` on Windows). See chapter 2.1, Process lifecycle.
- **No stray kills.** Before signalling a recorded process, `ProcessTree` checks that its pid still has the same start time, so a pid the OS has since reused for an unrelated process is left alone.
- **Termination is handled.** `qa` and QAFlow Studio catch SIGINT and SIGTERM, stop what they launched, and kill any leftovers before exiting; a second signal force-kills at once. `qa host` stops every app it launched when it exits.

## 10.2 Remote hosts: threat model

A `qa host` (chapter 11) launches programs on one machine for a client on another. Its job is to let the person who set it up drive their own app remotely, and nobody else.

**What an attacker would want.** `app.start` takes a `binary` path and an `env` map, so whoever can call it can run any program, with any environment, as the user running `qa host`. The host token is therefore **as powerful as an SSH key for that account**, and `qa host` says so every time it starts.

**What protects it:**

| Layer | What it does |
|---|---|
| Loopback only | `qa host` binds `127.0.0.1`. Nothing on the network can open a connection to it; only processes on the host machine can, which in practice means the SSH tunnel's end |
| SSH tunnel | The client reaches the host with `ssh -L`, which supplies encryption and machine-level authentication (the user's SSH key or password). The host serves plain `ws://` and relies on the tunnel for both |
| A token on every request | `/control` and `/vm/<appId>` both need `?token=`. A missing or wrong one gets HTTP 401 before any WebSocket upgrade, so an unauthenticated peer never reaches the JSON-RPC handler or the VM service |
| Constant-time comparison | The token check compares every byte whatever the first difference, so timing reveals nothing about a guess |
| A strong token | 32 bytes from `Random.secure()`, as hex |
| One client | A second control connection is closed at once (code 4000) while one is connected, so another token holder can't act alongside an active session |
| VM-service auth code stays on the host | The proxy connects to the app's internal URI; the client only sees `/vm/<appId>`. A failed upstream connection is a 502 without the URI |
| Abandoned apps are stopped | A client that disappears, including one whose network dropped silently (missed pings), loses its apps after a 10 s grace period, and its device boots are cancelled at once |

**Token handling:**

- **Creation.** The token file (`~/.qa/host-token` by default) is created through a temporary file that is restricted to `600` before the token is written, then renamed into place. A folder `qa host` has to create is made `700`. An existing token file with group or other permissions is tightened to `600`. (On Windows, `chmod` isn't available and the file keeps its folder's access.)
- **Display.** `qa host` prints the token once, when it creates it, so you can copy it to the client.
- **On the client.** `project.yaml` refuses a `token:` key; `qa` reads `QA_HOST_TOKEN`; QAFlow Studio keeps tokens in `settings.json` (0600) and shows them only as `••••`.
- **In logs and errors.** The token travels in URL query strings, so the client redacts it wherever a URL is printed: the session logs the VM URI as `...?token=***` (`redactUri`), and connect errors are scrubbed (`redactToken`). Tests check the redaction, and a manual run through a loopback host found the token in none of the run logs, `results.json`, `junit.xml` or `report.html`.
- **Rotation.** Delete the token file and restart `qa host`; a new token is generated and printed. The old one stops working at once.

**What is not protected** (see also 10.3):

- **A token holder on the host machine.** Any local process that can read the token, or any local user who has it, can connect to `127.0.0.1:<port>` directly, without a tunnel.
- **Grace-period inheritance.** Any holder of the token who connects within 10 s of a disconnect inherits the previous client's running apps.
- **No `Origin` check.** The host doesn't look at the WebSocket `Origin` header; the token is the only gate, and a request without it still gets 401.
- **No TLS without the tunnel.** Forwarding the host's port to the network (rather than tunnelling it) would send the token in clear text.
- **The app's own VM service on the host** is as exposed there as it is locally (10.3): prebuilt apps run with VM-service auth codes disabled.

## 10.3 What is deliberately not protected

| Area | Situation | Why, and what to do |
|---|---|---|
| **The VM service while an app is under test** | It listens on `127.0.0.1` only. Apps launched with `flutter run` get an auth code in the URL. **Prebuilt apps are launched with auth codes disabled**, the same way `flutter_tools` launches desktop binaries, so any process on the same machine can connect to that port while the test runs and execute code in the app | Only drive prebuilt apps on machines you trust, which is the normal case for a developer machine or a CI runner |
| **Flows are trusted input** | A flow can drive the app however it likes, `runFlow` can reference files anywhere on disk, and `--env` values reach the app's UI | Review flows like code. There's no JavaScript and no shell access from flows |
| **Secret values at rest** | QAFlow Studio stores them, and host tokens, in plain JSON (mode 0600), not the macOS Keychain | Anyone with access to your user account can read them. The Keychain would be stronger, and is listed as a future improvement |
| **Secrets in artifacts** | Screenshots show what's on screen. Obscured fields show dots, but a secret typed into a normal field, or displayed by the app, appears in screenshots and element dumps | Treat `qa-out/` as sensitive. It's in `.gitignore`; check run folders before sharing them |
| **App output** | The log tail attached to failed steps, and `--verbose` output, include whatever the app prints | Don't log secrets in the app |
| **QAFlow Studio's sandbox** | The macOS App Sandbox is off. The studio has to start `flutter`, read any project folder and connect to the app under test | It has the same access as any developer tool you run |
| **The host token** | Whoever holds it can run any program as the host's user (10.2) | Treat it like an SSH key: keep the token file private, don't paste it into tickets or chat, and rotate it by deleting the file and restarting `qa host` |
| **The host connection without a tunnel** | There is no TLS; the WebSocket is plain `ws://` | Only reach a host through the SSH tunnel; never forward its port to the network |
| **Device state** | `qa` boots simulators and emulators but never shuts them down, and a device keeps whatever the app stored on it | Wipe or reset devices yourself when that matters; use the app's `onReset` hook for app state |

## 10.4 Checklist for teams

- Keep `lib/main_qa.dart` out of release build configurations (the default with `flutter build`).
- Declare passwords and tokens as **secrets**, never as `flows.env` values.
- Pin the toolkit with a git tag or commit ([Integration and CI](../integration.md)) so test machines run reviewed code.
- Run tests on machines you control. Prebuilt apps expose an unauthenticated local VM service during a run.
- Keep `qa-out/` out of version control, and review run folders before attaching them to bug reports.
- In CI, pass secrets from the CI system's secret store with `--env`. Don't echo them.
- For a remote host, reach it only through `ssh -L`, run `qa host` under an account used only for testing where you can, keep its token as private as an SSH key, and rotate it when someone leaves the team.
