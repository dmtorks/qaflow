# Releasing the QAFlow packages

`qaflow_protocol`, `qaflow_agent` and `qaflow` share one version and always move
together. Before 1.0, a breaking change bumps the minor version (0.1.0 to 0.2.0)
and a fix bumps the patch version (0.1.0 to 0.1.1). They depend on each other
with caret constraints on that shared version (`qaflow_protocol: ^0.2.0`), which
for a 0.x version means the same minor version. A test in `packages/qaflow`
(`test/release_tool_test.dart`) fails CI when the versions or the constraints
drift apart.

Each release gets one tag per package:

| Tag | Publishes |
|---|---|
| `qaflow_protocol-v<version>` | `packages/qaflow_protocol` |
| `qaflow_agent-v<version>` | `packages/qaflow_agent` |
| `qaflow-v<version>` | `packages/qaflow` |

Pushing a tag runs `.github/workflows/publish.yml`, which checks that the tag's
version is the package's pubspec version and that its CHANGELOG has a real entry
for it, then publishes to pub.dev through
[automated publishing](https://dart.dev/tools/pub/automated-publishing) (GitHub
OIDC, no stored token).

## Publish order

`qaflow_protocol` first, then `qaflow_agent` and `qaflow`. Both depend on
`qaflow_protocol ^<version>`, and pub.dev checks that against what is already
published. Inside the workspace that resolves locally, so `dart pub publish
--dry-run` passes even when the dependency is not on pub.dev yet; the real
publish does not.

Tag pushes start separate workflow runs that run at the same time, so the
workflow can't keep the order for you. Push the `qaflow_protocol` tag, wait
until `https://pub.dev/packages/qaflow_protocol` shows the new version, then
push the other two.

## Making a release

1. On a branch off `main`, bump everything with one command from the repo
   root:

   ```sh
   dart run tool/release.dart 0.2.0
   ```

   It refuses a version that isn't semver (`x.y.z`, optionally with a
   prerelease suffix such as `0.2.0-dev.1`) or isn't greater than the current
   one. It sets `version:` in the three pubspecs, sets the constraints between
   them to `^0.2.0`, sets `qaVersion` in
   `packages/qaflow/lib/src/remote/host_protocol.dart` (what `qa host`
   reports), and adds a `## 0.2.0 - <today>` entry with a placeholder bullet
   to each package's `CHANGELOG.md`. Then it prints the next steps.
2. Replace the placeholder bullet in each package CHANGELOG with the real
   changes, and add the release to the combined `CHANGELOG.md` at the root.
   The publish workflow refuses a CHANGELOG that still has the placeholder.
3. Commit, open a PR and merge it once CI is green.
4. On `main`, at the merge commit, tag and push in publish order:

   ```sh
   git checkout main && git pull
   git tag qaflow_protocol-v0.2.0
   git push origin qaflow_protocol-v0.2.0
   # wait for https://pub.dev/packages/qaflow_protocol to show 0.2.0
   git tag qaflow_agent-v0.2.0
   git push origin qaflow_agent-v0.2.0
   git tag qaflow-v0.2.0
   git push origin qaflow-v0.2.0
   ```

5. Watch the **Publish to pub.dev** runs in the Actions tab. If one fails on
   the version check, the tag points at the wrong commit: delete it
   (`git push origin :refs/tags/<tag>` and `git tag -d <tag>`), then tag the
   right commit.

## Publishing by hand

If automated publishing is unavailable, publish from a machine with the `dart`
from a Flutter SDK. Every package is in the root pub workspace, which contains
Flutter packages, so a plain Dart SDK can't resolve any of them. In order:

```sh
cd packages/qaflow_protocol
dart pub publish --dry-run   # must end with "Package has 0 warnings."
dart pub publish
# wait for https://pub.dev/packages/qaflow_protocol to show the version

cd ../qaflow_agent
dart pub publish --dry-run
dart pub publish

cd ../qaflow
dart pub publish --dry-run
dart pub publish
```

Then push the same tags, so the history matches. Their workflow runs fail
because the version is already on pub.dev; that is expected.

## One-time setup on pub.dev

For each of the three packages, as an uploader (or an admin of the publisher
that owns it):

1. Open `https://pub.dev/packages/<package>/admin`.
2. Under **Automated publishing**, choose **Enable publishing from GitHub
   Actions**.
3. Repository: `dmtorks/qaflow`.
4. Tag pattern, which must contain `{{version}}` and match the workflow's
   trigger:
   - `qaflow_protocol`: `qaflow_protocol-v{{version}}`
   - `qaflow_agent`: `qaflow_agent-v{{version}}`
   - `qaflow`: `qaflow-v{{version}}`
5. Optionally, require a GitHub Actions environment (for example `pub.dev`),
   and add `environment: pub.dev` to the `publish` job in
   `.github/workflows/publish.yml`. With required reviewers on that
   environment, a pushed tag waits for approval before it publishes. Without
   it, anyone who can push a matching tag can publish.

## Installing from GitHub

The tags also give a git dependency a stable ref, for apps that install from
the repository instead of pub.dev:

```yaml
dependencies:
  qaflow_agent:
    git:
      url: https://github.com/dmtorks/qaflow.git
      path: packages/qaflow_agent
      ref: qaflow_agent-v0.2.0
```
