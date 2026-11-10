import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'agent.dart';
import 'frames.dart';

/// One rendered frame of the RepaintBoundary from QaAgent.wrap, shared by
/// both screenshot transfer modes.
class ScreenshotImage {
  const ScreenshotImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.devicePixelRatio,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final double devicePixelRatio;
}

class Screenshot {
  static final GlobalKey boundaryKey = GlobalKey(debugLabel: 'qaflow_agent RepaintBoundary');

  /// Renders the RepaintBoundary to PNG bytes and reports its pixel size.
  static Future<ScreenshotImage> render({bool waitForFrame = true}) async {
    // Frames are paused while the app is hidden: waiting would just spend
    // the default limit finding that out, so skip straight to capturing
    // whatever is already rendered.
    if (waitForFrame && !Frames.paused) await Frames.next();
    final context = boundaryKey.currentContext;
    if (context == null || !context.mounted) {
      throw QaException(QaErrorCode.unsupported, 'screenshots need QaAgent.wrap() around the app in main_qa.dart');
    }
    final boundary = context.findRenderObject() as RenderRepaintBoundary;
    final devicePixelRatio = View.of(context).devicePixelRatio;
    final image = await boundary.toImage(pixelRatio: devicePixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw QaException(QaErrorCode.internal, 'PNG encoding returned null');
      return ScreenshotImage(
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: image.width,
        height: image.height,
        devicePixelRatio: devicePixelRatio,
      );
    } finally {
      image.dispose();
    }
  }

  /// Renders and writes the PNG to [path], or to a generated name under
  /// QaAgent.screenshotDirectory. Both processes share a filesystem in this
  /// mode, so the file path replaces a base64 payload.
  static Future<Map<String, Object?>> capture({String? path, bool waitForFrame = true}) async {
    final image = await render(waitForFrame: waitForFrame);
    final file = File(
      path ??
          '${QaAgent.screenshotDirectory}${Platform.pathSeparator}'
              'qa_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(image.bytes);
    return {
      'path': file.path,
      'width': image.width,
      'height': image.height,
      'devicePixelRatio': image.devicePixelRatio,
    };
  }
}
