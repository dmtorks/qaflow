import 'dart:io';

/// The real OS the app runs on. `defaultTargetPlatform` can be overridden in
/// debug builds; input kind and device actions must follow the actual OS.
/// Replaceable in tests, where `Platform` is the host's.
class AgentPlatform {
  static bool Function() isAndroid = _isAndroid;
  static bool Function() isIOS = _isIOS;

  static bool get isTouch => isAndroid() || isIOS();

  static void reset() {
    isAndroid = _isAndroid;
    isIOS = _isIOS;
  }

  static bool _isAndroid() => Platform.isAndroid;
  static bool _isIOS() => Platform.isIOS;
}
