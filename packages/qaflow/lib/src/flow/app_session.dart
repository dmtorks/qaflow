import '../device/device.dart';
import '../driver/qa_driver.dart';

/// What the flow runner needs from a running app. [QaSession] implements it
/// for real apps; tests use a fake.
abstract class AppSession {
  /// The driver for the current launch. May be a different object after a
  /// relaunch, so read it again after [start] or [reset].
  QaDriver get driver;

  bool get isRunning;

  /// True when [reset] can hot restart instead of relaunching.
  bool get supportsHotRestart;

  /// App output lines, across relaunches.
  Stream<String> get logs;

  /// Resolves the target device, booting it if needed, and returns it. Runs
  /// once; later calls return the same device. [start] calls it itself when
  /// nobody has.
  Future<DeviceInfo> prepareDevice({void Function(DeviceInfo device)? onBooting});

  /// The device, once prepared.
  DeviceInfo? get device;

  /// Rotation and deep links for the prepared device; unsupported on desktop.
  DeviceController get deviceController;

  /// Launches the app if it is not running.
  Future<void> start();

  /// Returns the app to a fresh state: runs the app's reset hook first when
  /// [clearState] is true, then hot restarts or relaunches, then waits for
  /// the agent and for the UI to settle. Starts the app if it is stopped.
  Future<void> reset({bool clearState = false});

  Future<void> stop();
}
