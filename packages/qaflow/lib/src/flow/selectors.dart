import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../driver/qa_driver.dart';

/// One selector candidate for a hit widget and how many widgets it matches.
class SelectorSuggestion {
  const SelectorSuggestion(this.selector, this.matches);
  final Selector selector;
  final int matches;

  /// One match is what a flow step needs; anything else is flagged.
  bool get isUnique => matches == 1;

  /// `id: login`, `text: Sign in, childOf: {id: form}`, `type: TextField, index: 1`.
  String get label => selectorLabel(selector);
}

/// Ranked selector suggestions for [hit] (spec decision 3): ids first, then
/// the hit's own text, then that text with `childOf` the nearest ancestor
/// that has an id, then type plus index. Duplicates are removed and every
/// candidate is counted with [countMatches] (normally `find`).
///
/// The agent lists the hit's ids before its ancestors' ids, so the first id
/// that is not the hit's own key or semantics identifier is the nearest
/// ancestor's.
Future<List<SelectorSuggestion>> suggestSelectors(
  ElementHit hit,
  Future<int> Function(Selector selector) countMatches,
) async {
  final ownIds = {hit.node.key, hit.node.semanticsId};
  final ids = <Selector>[];
  final texts = <Selector>[];
  final typed = <Selector>[];
  String? ancestorId;
  for (final s in hit.selectors) {
    if (s.id != null) {
      ids.add(Selector(id: s.id));
      if (ancestorId == null && !ownIds.contains(s.id)) ancestorId = s.id;
    } else if (s.text != null) {
      texts.add(Selector(text: s.text));
    } else if (s.type != null) {
      typed.add(Selector(type: s.type, index: s.index));
    }
  }
  final ordered = <Selector>[
    ...ids,
    ...texts,
    if (ancestorId != null)
      for (final t in texts)
        Selector(
          text: t.text,
          within: Selector(id: ancestorId),
        ),
    ...typed,
  ];
  final seen = <Selector>{};
  final out = <SelectorSuggestion>[];
  for (final s in ordered) {
    if (!seen.add(s)) continue;
    out.add(SelectorSuggestion(s, await countMatches(s)));
  }
  return out;
}

/// The first unique suggestion, else the first one (its `isUnique` is false,
/// which the screen flags); null for an empty list.
SelectorSuggestion? bestSuggestion(List<SelectorSuggestion> suggestions) {
  for (final s in suggestions) {
    if (s.isUnique) return s;
  }
  return suggestions.isEmpty ? null : suggestions.first;
}

/// The flow-style inline form of [s], using the YAML keys the parser reads
/// (`within` is written as `childOf`).
String selectorLabel(Selector s) => [
  if (s.id != null) 'id: ${s.id}',
  if (s.text != null) 'text: ${s.text}',
  if (s.type != null) 'type: ${s.type}',
  if (s.index != null) 'index: ${s.index}',
  if (s.enabled != null) 'enabled: ${s.enabled}',
  if (s.within != null) 'childOf: {${selectorLabel(s.within!)}}',
].join(', ');
