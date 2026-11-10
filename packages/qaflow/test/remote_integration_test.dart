@Tags(['integration'])
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:qaflow/qaflow.dart';
import 'package:test/test.dart';

/// Runs the macOS demo app's flows through a `qa host` started in this
/// process, on loopback, with the host's real devices and launchers: the
/// same path a run against another machine takes, minus the SSH tunnel.
///
/// Builds and opens the demo app, so it runs only on demand:
/// `dart test -P integration test/remote_integration_test.dart`.
void main() {
  test('the demo app flows pass through a loopback qa host', () async {
    final demo = p.normalize(p.absolute('..', '..', 'example', 'demo_app'));
    final file = ProjectFile.load(p.join(demo, '.qa', 'project.yaml'));
    const token = 'loopback-integration-token';
    final server = await HostServer.start(port: 0, token: token);
    addTearDown(server.close);
    final host = RemoteHostConfig(url: Uri.parse('ws://127.0.0.1:${server.port}'), project: demo);

    final parser = FlowParser();
    final flows = selectFlows(
      [for (final path in discoverFlowFiles(file.flowFolders)) parser.parseFile(path)],
      include: file.includeTags,
      exclude: file.excludeTags,
    );
    expect(flows, isNotEmpty);

    final out = Directory.systemTemp.createTempSync('qa_remote_integration');
    addTearDown(() => out.deleteSync(recursive: true));
    final log = <String>[];
    final run = await TestRun.start(
      TestRunRequest(
        config: file.configWithHost(host),
        flows: flows,
        parser: parser,
        outDir: out.path,
        env: file.flowEnv,
        appRoot: file.appRoot,
        // Compares against the committed baselines and never writes new ones.
        baselines: BaselineMode.strict,
        log: log.add,
      ),
      createSession: (config, runDir, log) => QaSession.create(
        config,
        screenshotDirectory: runDir,
        log: log,
        environment: const {QaSession.hostTokenVariable: token},
      ),
    );
    final report = StringBuffer();
    final console = ConsoleReporter(report);
    await for (final e in run.events) {
      console.onEvent(e);
    }
    final outcome = await run.done;

    expect(
      log.any((m) => m.startsWith('connecting to ws://127.0.0.1:${server.port}/vm/')),
      isTrue,
      reason: 'the VM service should be reached through the host proxy',
    );
    expect(log.join('\n'), isNot(contains(token)));
    expect(
      outcome.isSuccess,
      isTrue,
      reason: '$report\nlog tail:\n${log.reversed.take(60).toList().reversed.join('\n')}',
    );
    expect(outcome.result.flows, hasLength(flows.length));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
