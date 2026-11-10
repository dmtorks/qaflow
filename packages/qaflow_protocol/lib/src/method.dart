import 'key_chord.dart';
import 'node.dart';
import 'screenshot_transfer.dart';
import 'selector.dart';

/// The commands the agent serves, one VM service extension each.
enum QaMethod {
  /// Checks the agent is installed and reports its protocol version.
  ping,

  /// Lists the widgets on screen as [QaNode]s, optionally for one view or including the uninteresting ones.
  elements,

  /// Lists the [QaNode]s a [Selector] matches.
  find,

  /// Reports the widget at an x, y point in a view.
  elementAt,

  /// Taps a widget picked by a [Selector], or a point.
  tap,

  /// Long-presses a widget picked by a [Selector], or a point.
  longPress,

  /// Moves a mouse pointer over a widget or a point. Unsupported on touch platforms.
  hover,

  /// Drags from a widget or a point.
  drag,

  /// Scrolls a widget or the view at a point.
  scroll,

  /// Types text into the focused field or one picked by a [Selector].
  enterText,

  /// Deletes characters before the cursor in a text field.
  eraseText,

  /// Replaces the whole text of a text field.
  setText,

  /// Presses a [KeyChord], such as `enter` or `mod+a`.
  pressKey,

  /// Waits until the app has no pending frames, or until it is stable, within a timeout.
  waitForIdle,

  /// Captures the app as a PNG, returned as set by [ScreenshotTransfer].
  screenshot,

  /// Runs the app's reset hook to clear its persisted state.
  resetState,

  /// Sends a system back event. Android only.
  back,

  /// Dismisses the on-screen keyboard.
  hideKeyboard,

  /// Sets the device orientation. Used on iOS.
  setOrientation;

  /// The VM service extension the agent registers for this method, such as
  /// `ext.qa.tap`.
  String get extensionName => 'ext.qa.$name';
}
