// Bumps qaflow_protocol, qaflow_agent and qaflow to one new version: the
// pubspec versions, the caret constraints between them, a CHANGELOG entry in
// each and qaflow's qaVersion, then prints the PR and tag steps.
//
//   dart run tool/release.dart <version>
//
// Run from the repo root. It edits files only; it never commits, tags or
// publishes. See tool/publish.md for the whole release process.

import 'dart:io';

import 'src/release.dart';

void main(List<String> args) {
  if (args.length != 1 || args.single.startsWith('-')) {
    stderr.writeln('usage: dart run tool/release.dart <version>');
    exit(64);
  }
  try {
    final plan = planRelease(Directory.current.path, args.single, DateTime.now());
    applyRelease(Directory.current.path, plan);
    for (final path in plan.files.keys) {
      stdout.writeln('updated $path');
    }
    stdout.writeln();
    stdout.write(nextSteps(plan.to));
  } on ReleaseException catch (e) {
    stderr.writeln('release: $e');
    exit(1);
  }
}
