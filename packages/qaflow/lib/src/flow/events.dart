import 'dart:typed_data';

import '../device/device.dart';
import '../screenshot/screenshot_comparison.dart';

enum StepStatus { passed, failed, warned, skipped }

enum FlowStatus { passed, failed, flaky, error, notRun }

class StepError {
  const StepError(this.code, this.message);
  factory StepError.fromJson(Map<String, Object?> json) => StepError(json['code'] as String, json['message'] as String);
  final String code;
  final String message;
  Map<String, Object?> toJson() => {'code': code, 'message': message};
}

class FlowInfo {
  const FlowInfo({required this.name, required this.file, required this.slug, this.tags = const []});
  final String name;

  /// Absolute path of the flow file.
  final String file;

  /// Unique within the run; names the flow's output folder.
  final String slug;
  final List<String> tags;
}

sealed class RunEvent {
  RunEvent({DateTime? time}) : time = time ?? DateTime.now();
  final DateTime time;
}

class RunStarted extends RunEvent {
  RunStarted({required this.runId, required this.project, required this.mode, required this.flows, super.time});
  final String runId;
  final String project;
  final String mode;
  final List<FlowInfo> flows;
}

/// The target device was shut down and is being booted.
class DeviceBooting extends RunEvent {
  DeviceBooting({required this.device, super.time});
  final DeviceInfo device;
}

/// The device is up; the app launches on it next.
class DeviceReady extends RunEvent {
  DeviceReady({required this.device, super.time});
  final DeviceInfo device;
}

class FlowStarted extends RunEvent {
  FlowStarted({required this.flow, required this.attempt, super.time});
  final FlowInfo flow;
  final int attempt;
}

class StepStarted extends RunEvent {
  StepStarted({required this.flow, required this.stepId, required this.label, required this.command, super.time});
  final FlowInfo flow;

  /// Dotted position: `3`, `3.2`, `start.1`, `4.2.1`.
  final String stepId;
  final String label;
  final String command;
}

class StepFinished extends RunEvent {
  StepFinished({
    required this.flow,
    required this.stepId,
    required this.label,
    required this.command,
    required this.status,
    required this.duration,
    this.error,
    this.artifacts = const [],
    this.note,
    this.logTail = const [],
    this.comparison,
    super.time,
  });
  final FlowInfo flow;
  final String stepId;
  final String label;
  final String command;
  final StepStatus status;
  final Duration duration;
  final StepError? error;

  /// Paths relative to the run folder.
  final List<String> artifacts;
  final String? note;

  /// App output before a failure; empty otherwise.
  final List<String> logTail;

  /// The result of an `assertScreenshot` step; null for any other command.
  final ScreenshotComparison? comparison;
}

/// A screenshot taken after a UI step for a live view. Held in memory only;
/// never written to the run folder.
class StepPreview extends RunEvent {
  StepPreview({required this.flow, required this.stepId, required this.png, super.time});
  final FlowInfo flow;
  final String stepId;
  final Uint8List png;
}

class AppLog extends RunEvent {
  AppLog({required this.line, super.time});
  final String line;
}

class FlowFinished extends RunEvent {
  FlowFinished({required this.flow, required this.status, required this.duration, required this.attempts, super.time});
  final FlowInfo flow;
  final FlowStatus status;
  final Duration duration;
  final int attempts;
}

class RunFinished extends RunEvent {
  RunFinished({required this.duration, required this.counts, this.error, super.time});
  final Duration duration;
  final Map<FlowStatus, int> counts;

  /// Why the run stopped early (launch or connection failure), if it did.
  final String? error;

  int count(FlowStatus status) => counts[status] ?? 0;

  bool get isSuccess =>
      error == null && count(FlowStatus.failed) == 0 && count(FlowStatus.error) == 0 && count(FlowStatus.notRun) == 0;
}
