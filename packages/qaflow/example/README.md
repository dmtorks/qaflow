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

Commands, run from the app's folder:

```sh
dart run qaflow:qa validate --config .qa/project.yaml
dart run qaflow:qa test --config .qa/project.yaml --out qa-out
dart run qaflow:qa ping --project .
```

The app needs `qaflow_agent` and a `lib/main_qa.dart` that calls `QaAgent.install()`.
