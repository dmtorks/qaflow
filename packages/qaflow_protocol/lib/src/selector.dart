import 'dart:convert';

/// Describes which widget a command targets. Fields combine with AND.
class Selector {
  /// A selector matching widgets that satisfy every given field.
  const Selector({
    this.text,
    this.textRegex,
    this.id,
    this.key,
    this.semanticsId,
    this.type,
    this.index,
    this.enabled,
    this.within,
  });

  /// Reads the map written by [toJson].
  factory Selector.fromJson(Map<String, Object?> json) => Selector(
    text: json['text'] as String?,
    textRegex: json['textRegex'] as String?,
    id: json['id'] as String?,
    key: json['key'] as String?,
    semanticsId: json['semanticsId'] as String?,
    type: json['type'] as String?,
    index: (json['index'] as num?)?.toInt(),
    enabled: json['enabled'] as bool?,
    within: json['within'] == null ? null : Selector.fromJson((json['within'] as Map).cast<String, Object?>()),
  );

  /// Text the widget shows, compared after trimming surrounding whitespace.
  final String? text;

  /// A regular expression the widget's whole text must match.
  final String? textRegex;

  /// Matches either the widget's `ValueKey<String>` or its Semantics
  /// identifier.
  final String? id;

  /// The value of the widget's `ValueKey<String>`.
  final String? key;

  /// The widget's Semantics identifier.
  final String? semanticsId;

  /// The widget's runtime type name, such as `TextField`.
  final String? type;

  /// Picks one match, counted from 0 in tree order, when several match.
  final int? index;

  /// Match only enabled (true) or disabled (false) widgets.
  final bool? enabled;

  /// Match only widgets inside one that this selector matches.
  final Selector? within;

  /// Whether no field identifies a widget. [index] and [enabled] only narrow
  /// a match, so a selector with just those is empty, and the agent rejects
  /// it.
  bool get isEmpty =>
      text == null &&
      textRegex == null &&
      id == null &&
      key == null &&
      semanticsId == null &&
      type == null &&
      within == null;

  /// This selector as JSON, leaving out null fields.
  Map<String, Object?> toJson() => {
    if (text != null) 'text': text,
    if (textRegex != null) 'textRegex': textRegex,
    if (id != null) 'id': id,
    if (key != null) 'key': key,
    if (semanticsId != null) 'semanticsId': semanticsId,
    if (type != null) 'type': type,
    if (index != null) 'index': index,
    if (enabled != null) 'enabled': enabled,
    if (within != null) 'within': within!.toJson(),
  };

  @override
  bool operator ==(Object other) => other is Selector && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() => 'Selector(${jsonEncode(toJson())})';
}
