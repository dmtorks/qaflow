# Remote hosts

A **QA host** lets `qa` on one machine (the *client*, typically a Mac) run flows against an app that runs on another machine (the *host*, for example a cloud Windows machine you reach by Remote Desktop). The host's desktop counts, and so do its simulators and emulators. The host runs one small daemon, `qa host`; everything else stays on the client.

## When to use it

- **A platform needs its own OS.** A Windows desktop app needs Windows; iOS simulators need macOS.
- **The devices are elsewhere.** A Mac with simulators, driven from a Linux CI box.

What stays on the client: the flow files (they are parsed there, so the host never sees them), the reports, the run folders, screenshots and baselines. Only the app's source or build lives on the host, at a folder you configure. Nothing syncs it there for you.

## Set up the host

1. Install what a local run would need there: Flutter with the toolchain for the target (what `flutter doctor` asks for), and for Android the Android SDK and an AVD.
2. Install the CLI: `dart pub global activate qaflow`.
3. Put a checkout of your app there, with `qaflow_agent` and `lib/main_qa.dart` as for a local run (see [Integration and CI](integration.md)).
4. Make SSH reach the machine (on Windows, enable **OpenSSH Server**).
5. Start the host:

   ```sh
   qa host [--port 7777] [--token-file <file>]
   ```

   It prints `QA host listening on 127.0.0.1:7777`. The first start generates a token, saves it in the token file and prints it once, with the commands and settings the client needs.

| Option | Default | Meaning |
|---|---|---|
| `--port <n>` | `7777` | Port to listen on, on `127.0.0.1` only |
| `--token-file <file>` | `~/.qa/host-token` (`%USERPROFILE%\.qa\host-token` on Windows) | The access token; created and printed once if missing |

`qa host` runs until you stop it with Ctrl-C (or SIGTERM), which stops every app it launched.

### The token

- It is 64 hex characters from a secure random source, stored in the token file with mode 600 (in a folder made 700). On Windows the file keeps whatever access its folder grants, so keep it under your own profile.
- An existing token file is reused; one with group or other permissions is tightened to 600 first.
- **To rotate it,** delete the token file and restart `qa host`.
- Anyone with the token can run programs as you on the host; `qa host` says so every time it starts. Treat it like an SSH key.

### Windows hosts

`qa host` prints these notes when it starts on Windows:

- **Start it from a terminal inside the logged-in Remote Desktop session,** not over SSH. Apps started from an SSH session have no desktop, so a Windows desktop app has no window to render.
- **Keep the desktop rendering.** Flutter stops producing frames when its window can't be shown, and every input step then fails with `not_ready`. Keep the RDP window open (minimised is fine), or, before disconnecting, run `tscon %sessionname% /dest:console` in the session so it keeps a display.
- **Android emulators** need hardware virtualization inside the VM: the cloud machine must offer nested virtualization, and the emulator uses the Windows Hypervisor Platform (WHPX).
- **iOS simulators are not available on Windows.** They need a macOS host.

## Use it from the client

1. **Open the tunnel**, and leave it running:

   ```sh
   ssh -N -L 7777:127.0.0.1:7777 <user>@<host>
   ```

2. **Give `qa` the token** through the environment. It is never read from the project file.

   ```sh
   export QA_HOST_TOKEN=<the token qa host printed>
   ```

3. **Name the host**, in the project file:

   ```yaml
   app:
     source: .                  # a path on the host, relative to host.project
   host:
     url: ws://127.0.0.1:7777   # default; the local end of the SSH tunnel
     project: C:\src\myapp      # the folder on the host that contains .qa/; required
   ```

   or on the command line:

   ```sh
   qa test --config .qa/project.yaml --host ws://127.0.0.1:7777 --host-project 'C:\src\myapp'
   ```

4. **Check it** with `qa ping --host ws://127.0.0.1:7777 --host-project <path>`, which launches the app on the host, pings the agent and saves one screenshot locally.

### Command-line flags

`qa test`, `qa ping` and `qa smoke` take:

| Flag | Effect |
|---|---|
| `--host <url>` | Use this host, overriding the file's URL |
| `--host-project <path>` | The project folder on the host. Alone, it uses the file's URL or the default `ws://127.0.0.1:7777` |
| `--host none` | Run on this machine even when the file names a host; paths are resolved locally again |

`--host` with no project folder anywhere, a bad URL, and `--host none` together with `--host-project` are usage errors (exit 64).

### Project file rules

- `host.project` is required and must not be blank.
- `host.url` must be a `ws://` or `wss://` URL with a host name. `qa host` itself serves plain `ws://`; the SSH tunnel provides the encryption.
- A `token:` key under `host:` is an error: `the host token is never read from the project file; set QA_HOST_TOKEN instead`.
- `app.source` and `app.binary` (and `--project` and `--binary`) are **paths on the host**. They are sent as written and checked there, not on the client.

## What changes for a run on a host

| Area | Local | On a host |
|---|---|---|
| No `device:` set | This machine's desktop | The host's desktop |
| Flutter SDK | Found on this machine | Found on the host, on the first launch from source (a host that only runs prebuilt binaries needs none) |
| App paths | Resolved against the app root here | Host paths, resolved against `host.project` there |
| `ios:` and `android:` devices | Booted here | Booted on the host |
| Baseline device keys | This machine's OS (`macos-27.0`) | The host's (`windows-10.0`) |
| Reports, run folders, baselines | On this machine | On this machine |

A host run with no local project file has no app root, so `assertScreenshot` can't find baselines and fails with `bad_request`.

## One client at a time

- The host serves one client at a time. A second one is refused with `QA host is in use by another client`.
- Each connection is pinged every 5 s, so a client that vanished (a laptop that dropped off the network) releases the host instead of holding it.
- When a client goes away, the host stops that client's apps after a **10 s grace period**. A client that connects with the token within that period inherits them; `qa` stops the apps it launched before running again, so a reconnect never runs two copies.

## Security

- `qa host` listens on `127.0.0.1` only, so nothing on the network can connect directly; the SSH tunnel is the network path, and it provides encryption and machine-level authentication. Never forward the host's port to the network.
- Every request needs the token; a missing or wrong one gets HTTP 401.
- The token travels in the connection URL, so `qa` replaces it with `***` wherever it prints a URL or an error.
- The app's own VM service address, with its auth code, never leaves the host.

## Known limits

- One client per host.
- No TLS of its own: plain `ws://` on loopback, behind the SSH tunnel.
- Any holder of the token who connects within 10 s of a disconnect inherits the previous client's apps.
- Cancelling a device boot only stops the client waiting; the host keeps booting until the client disconnects.
- No source sync: the app's source or build must already be on the host, at the configured folder.
- No iOS from a Windows or Linux host.
- Verified over loopback on one Mac (host and client on the same machine). A real Windows host has not been tried yet.

For error messages and fixes, see [Troubleshooting: remote hosts](troubleshooting.md#remote-hosts).
