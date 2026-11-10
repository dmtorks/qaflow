import '../flow/events.dart';
import 'comparison_text.dart';

/// Human-readable progress on a terminal.
class ConsoleReporter {
  ConsoleReporter(this.out, {this.verbose = false});
  final StringSink out;

  /// Also print app output lines.
  final bool verbose;

  /// Slugs of flows that have printed a `FLOW` header. A flow can finish
  /// without one: notRun (the whole run failed to launch) or error (e.g.
  /// session.reset() failed before FlowStarted for a non-first flow).
  final Set<String> _started = {};

  void onEvent(RunEvent e) {
    switch (e) {
      case RunStarted():
        out.writeln('Running ${e.flows.length} flow(s) against ${e.project} (${e.mode})');
      case DeviceBooting():
        out.writeln('Booting ${e.device.title}…');
      case DeviceReady():
        out.writeln('Device: ${e.device.title}');
      case FlowStarted():
        _started.add(e.flow.slug);
        out.writeln('');
        out.writeln('FLOW ${e.flow.name}${e.attempt > 1 ? ' (attempt ${e.attempt})' : ''}');
      case StepStarted() || StepPreview():
        break;
      case StepFinished():
        final indent = '  ' * ('.'.allMatches(e.stepId).length + 1);
        final tag = switch (e.status) {
          StepStatus.passed => 'PASS',
          StepStatus.failed => 'FAIL',
          StepStatus.warned => 'WARN',
          StepStatus.skipped => 'SKIP',
        };
        final detail = mismatchDetail(e.error);
        final timing = e.status == StepStatus.skipped || e.comparison != null
            ? ''
            : ' (${e.duration.inMilliseconds} ms)';
        final note = e.note == null ? '' : ' - ${e.note}';
        out.writeln('$indent$tag ${e.stepId} ${e.label}${detail == null ? timing : ' ($detail)'}$note');
        if (e.error != null && detail == null) out.writeln('$indent     ${e.error!.code}: ${e.error!.message}');
      case AppLog():
        if (verbose) out.writeln('    [app] ${e.line}');
      case FlowFinished():
        if (_started.remove(e.flow.slug)) {
          out.writeln('  => ${_status(e.status)} in ${_seconds(e.duration)}');
        } else {
          // No FLOW header ran for this one; name it so N flows do not
          // print as N identical anonymous lines.
          out.writeln('');
          out.writeln('${_status(e.status)} ${e.flow.name}');
        }
      case RunFinished():
        out.writeln('');
        out.writeln(
          '${e.count(FlowStatus.passed)} passed, ${e.count(FlowStatus.failed)} failed, '
          '${e.count(FlowStatus.flaky)} flaky, ${e.count(FlowStatus.error)} errors, '
          '${e.count(FlowStatus.notRun)} not run in ${_seconds(e.duration)}',
        );
        if (e.error != null) out.writeln('Run stopped: ${e.error}');
    }
  }

  static String _status(FlowStatus s) => switch (s) {
    FlowStatus.notRun => 'NOT RUN',
    _ => s.name.toUpperCase(),
  };

  static String _seconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
}
