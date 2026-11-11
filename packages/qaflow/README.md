# qaflow

The QAFlow engine and the `qa` command. It
launches a Flutter app that has the `qaflow_agent` entrypoint, connects to the Dart VM
service and runs YAML flows: taps, text input, assertions, screenshots with per-device
baselines, and JUnit-style reports. It is pure Dart and has no Flutter dependency.

## Install

Add it to the project you test, then run the CLI through `dart run`:

```sh
dart pub add dev:qaflow
dart run qaflow:qa --help
```

Or activate it globally:

```sh
dart pub global activate qaflow
qa --help
```

The app under test needs `qaflow_agent` and a `lib/main_qa.dart` entrypoint.

## Use

```sh
qa validate --config .qa/project.yaml
qa test --config .qa/project.yaml --out qa-out
```

Other subcommands are `ping`, `smoke` and `host`. See
[example/README.md](example/README.md) for a project file and a flow.

## Subflows

Steps several flows share, such as logging in, go in a subflow: an ordinary flow file that other
flows run with `runFlow`. Keep subflows in `.qa/subflows/`, outside the folders listed in
`flows.folders`, so they don't also run on their own.

`.qa/subflows/login.yaml`:

```yaml
name: Log in
env:
  USERNAME: alice
  PASSWORD: secret
---
- tapOn: {id: username}
- inputText: ${USERNAME}
- tapOn: {id: password}
- inputText: ${PASSWORD}
- pressKey: enter
```

A flow runs it with a path relative to the flow's own file:

```yaml
name: Open the dialog after logging in
---
- launchApp
- runFlow: ../subflows/login.yaml
- tapOn: {id: open_dialog}
```

The map form passes variables, which win over the subflow's own `env`, and can make the step
conditional:

```yaml
- runFlow:
    file: ../subflows/login.yaml
    env: {PASSWORD: wrong}
- assertVisible: Wrong password
- runFlow:
    when: {visible: Accept cookies}
    commands:
      - tapOn: Accept
```

`commands:` runs an inline list instead of a file. A missing subflow file or a cycle
(`a.yaml -> b.yaml -> a.yaml`) is reported before the run starts. In reports, steps inside a
subflow are numbered under the `runFlow` step: `2.1`, `2.2`, and so on.

## More

QAFlow is three packages: [qaflow_agent](https://pub.dev/packages/qaflow_agent) goes in the app
under test, this package runs the flows, and [qaflow_protocol](https://pub.dev/packages/qaflow_protocol)
holds the messages they share.

Read the [QAFlow docs](https://github.com/dmtorks/qaflow) for the command reference, CI setup,
remote hosts and troubleshooting, and report issues on its
[issue tracker](https://github.com/dmtorks/qaflow/issues).
