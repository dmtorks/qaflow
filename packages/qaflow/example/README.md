# qaflow example

A QAFlow project lives in a `.qa/` folder at the root of your Flutter app.

`.qa/project.yaml`

```yaml
app:
  source: .
flows:
  folders: [.qa/flows]
```

`.qa/flows/dialog.yaml`. The ids and texts in this flow (`open_dialog`, `Enter a value`, `OK`) come from
the repo's demo app; change them to match the widgets in your app.

```yaml
name: Dialog writes its value back
tags: [dialog]
---
- launchApp
- tapOn:
    id: open_dialog
- assertVisible: Enter a value
- inputText: hello
- tapOn: OK
- assertVisible: hello
- takeScreenshot: dialog-done
```

Shared steps go in a subflow outside the flow folders, so it only runs when a flow calls it.
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

`.qa/flows/login_wrong_password.yaml` runs it with a different password:

```yaml
name: Wrong password shows an error
---
- launchApp
- runFlow:
    file: ../subflows/login.yaml
    env: {PASSWORD: wrong}
- assertVisible: Wrong password
```

Commands, run from the app's folder:

```sh
dart run qaflow:qa validate --config .qa/project.yaml
dart run qaflow:qa test --config .qa/project.yaml --out qa-out
dart run qaflow:qa ping --project .
```

The app needs `qaflow_agent` and a `lib/main_qa.dart` that calls `QaAgent.install()`.
