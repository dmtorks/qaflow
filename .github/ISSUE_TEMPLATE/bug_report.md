---
name: Bug report
about: Something in QAFlow does not work as documented
title: ''
labels: bug
assignees: ''
---

**What happened**

A clear description of the problem, and what you expected instead.

**Versions**

- qaflow version (`dart pub global list`, or `qaflow` and `qaflow_agent` in your app's `pubspec.lock`):
- Flutter version (`flutter --version`):

**Platform and device**

- Machine running `qa` (OS and version):
- Target (`macos`, `windows`, `linux`, `flutter-tester`, `ios:<simulator>`, `android:<emulator>`), with its OS version:
- Debug or profile, from source or a prebuilt binary:
- Through a remote host (`qa host`)? If so, the host's OS:

**Project file**

Your `.qa/project.yaml`, with secret values removed:

```yaml

```

**Flow**

The flow that fails (and any subflows it runs), as small as you can make it:

```yaml

```

**Report or console output**

The output of `qa test ... --verbose`, and the failing step's entry from `report.html` or `results.json`. Attaching the zipped run folder (`qa-out/<run id>/`) helps most. Run folders can contain typed values in screenshots and element dumps, so check them before sharing.

```text

```
