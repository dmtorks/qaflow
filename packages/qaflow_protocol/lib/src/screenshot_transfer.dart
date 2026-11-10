/// How the agent returns screenshot pixels to the driver.
///
/// `inline` returns base64-encoded PNG bytes in the response so the driver
/// can write the file itself; `file` has the agent write the PNG to a path
/// on a filesystem it shares with the driver. `inline` is the default: the
/// macOS App Sandbox, on by default for debug and profile builds, lets the
/// app under test write only inside its own container, so `file` needs an
/// unsandboxed app or a file-access entitlement.
enum ScreenshotTransfer {
  /// Base64-encoded PNG bytes in the response.
  inline,

  /// A PNG the agent writes to a path the driver gives.
  file;

  /// The value named [wire]. Throws an [ArgumentError] for an unknown one.
  static ScreenshotTransfer fromWire(String wire) => values.firstWhere(
    (t) => t.name == wire,
    orElse: () => throw ArgumentError.value(wire, 'wire', 'unknown ScreenshotTransfer'),
  );
}
