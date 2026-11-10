/// Axis-aligned rectangle in logical pixels, view coordinate space.
class QaRect {
  /// A rectangle with its top-left corner at [x], [y].
  const QaRect(this.x, this.y, this.width, this.height);

  /// Reads the map written by [toJson].
  factory QaRect.fromJson(Map<String, Object?> json) => QaRect(
    (json['x'] as num).toDouble(),
    (json['y'] as num).toDouble(),
    (json['width'] as num).toDouble(),
    (json['height'] as num).toDouble(),
  );

  /// The left edge.
  final double x;

  /// The top edge.
  final double y;

  /// The width, from [x] to [right].
  final double width;

  /// The height, from [y] to [bottom].
  final double height;

  /// The horizontal centre.
  double get centerX => x + width / 2;

  /// The vertical centre.
  double get centerY => y + height / 2;

  /// The right edge.
  double get right => x + width;

  /// The bottom edge.
  double get bottom => y + height;

  /// Whether this rectangle and [other] overlap by a non-zero area. Rectangles
  /// that only share an edge do not intersect.
  bool intersects(QaRect other) => x < other.right && other.x < right && y < other.bottom && other.y < bottom;

  /// This rectangle as `x`, `y`, `width` and `height` keys.
  Map<String, Object?> toJson() => {'x': x, 'y': y, 'width': width, 'height': height};

  @override
  bool operator ==(Object other) =>
      other is QaRect && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'QaRect($x, $y, $width, $height)';
}

/// One widget in an `elements` snapshot or a `find` result.
class QaNode {
  /// A node with every field given; the agent builds these.
  const QaNode({
    required this.nodeId,
    required this.parentId,
    required this.type,
    required this.text,
    required this.key,
    required this.semanticsId,
    required this.label,
    required this.rect,
    required this.viewId,
    required this.visible,
    required this.interactive,
    required this.enabled,
    this.visibleRect,
  });

  /// Reads the map written by [toJson].
  factory QaNode.fromJson(Map<String, Object?> json) => QaNode(
    nodeId: (json['nodeId'] as num).toInt(),
    parentId: (json['parentId'] as num?)?.toInt(),
    type: json['type'] as String,
    text: json['text'] as String?,
    key: json['key'] as String?,
    semanticsId: json['semanticsId'] as String?,
    label: json['label'] as String?,
    rect: json['rect'] == null ? null : QaRect.fromJson((json['rect'] as Map).cast<String, Object?>()),
    viewId: (json['viewId'] as num).toInt(),
    visible: json['visible'] as bool,
    interactive: json['interactive'] as bool,
    enabled: json['enabled'] as bool,
    visibleRect: json['visibleRect'] == null
        ? null
        : QaRect.fromJson((json['visibleRect'] as Map).cast<String, Object?>()),
  );

  /// The node's position in the agent's walk of the widget tree. Ids are
  /// only meaningful within the snapshot or result they came from.
  final int nodeId;

  /// The [nodeId] of the nearest listed ancestor in an `elements` snapshot,
  /// or null at the top or in a `find` result.
  final int? parentId;

  /// The widget's runtime type, such as `ElevatedButton`.
  final String type;

  /// The text the widget shows: a `Text`'s data, an editable field's value
  /// (null when it is obscured, such as a password) or a tooltip's message.
  final String? text;

  /// The value of the widget's `ValueKey<String>`, if it has one.
  final String? key;

  /// The identifier of a `Semantics` widget, if it sets one.
  final String? semanticsId;

  /// The label of a `Semantics` widget, if it sets one.
  final String? label;

  /// The widget's bounds in the view, or null when it has no laid-out box.
  final QaRect? rect;

  /// The id of the Flutter view the widget is drawn in.
  final int viewId;

  /// Whether any part of the widget is inside the view and its scroll
  /// viewports, that is, whether [visibleRect] is non-null.
  final bool visible;

  /// Whether the widget takes input: a button, a gesture detector, a text
  /// field, a checkbox, a scrollable and similar.
  final bool interactive;

  /// Whether the widget accepts input now. False for a button with no
  /// callback or a read-only field; true for widgets that are not
  /// [interactive].
  final bool enabled;

  /// The part of [rect] inside the view and every enclosing scroll viewport;
  /// null when none of it is visible.
  final QaRect? visibleRect;

  /// This node as a JSON map, with null fields written as null.
  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'parentId': parentId,
    'type': type,
    'text': text,
    'key': key,
    'semanticsId': semanticsId,
    'label': label,
    'rect': rect?.toJson(),
    'viewId': viewId,
    'visible': visible,
    'interactive': interactive,
    'enabled': enabled,
    'visibleRect': visibleRect?.toJson(),
  };

  @override
  String toString() => '$type(id=$nodeId${key != null ? ', key=$key' : ''}${text != null ? ', text="$text"' : ''})';
}
