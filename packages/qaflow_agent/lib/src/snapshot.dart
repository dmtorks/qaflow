import 'package:flutter/rendering.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'finder.dart';

class Snapshot {
  /// Interesting nodes (or all when [all]) with parentId pointing at the
  /// nearest interesting ancestor.
  static List<Map<String, Object?>> elements({int? viewId, bool all = false}) {
    final candidates = QaFinder.collect();
    final kept = <Candidate>[
      for (final c in candidates)
        if ((all || c.interesting) && (viewId == null || c.viewId == viewId)) c,
    ];
    final keptIds = {for (final c in kept) c.node.nodeId};
    return [
      for (final c in kept) {...c.node.toJson(), 'parentId': _parentIdWithin(c, keptIds)},
    ];
  }

  static int? _parentIdWithin(Candidate c, Set<int> keptIds) {
    for (var p = c.parent; p != null; p = p.parent) {
      if (keptIds.contains(p.node.nodeId)) return p.node.nodeId;
    }
    return null;
  }

  /// The innermost interesting node under [point] plus selector suggestions
  /// for the recorder, most specific first. A bare control that only fills
  /// an enclosing control (see [_outermostSameControl]) reports that control.
  static Map<String, Object?> elementAt(Offset point, int viewId) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, point, viewId);
    final hitObjects = <RenderObject>{
      for (final entry in result.path)
        if (entry.target is RenderObject) entry.target as RenderObject,
    };
    final candidates = QaFinder.collect();
    bool isHit(Candidate c) => c.box != null && hitObjects.contains(c.box) && c.interesting;
    Candidate? best;
    for (final c in candidates) {
      if (isHit(c)) best = c;
    }
    if (best == null) {
      throw QaException(QaErrorCode.notFound, 'nothing interesting at ${point.dx},${point.dy}');
    }
    // Suggestions come from the innermost hit, as they always have; only the
    // reported node climbs to the control the mirror outlines.
    final target = best;
    final reported = _outermostSameControl(best, isHit);
    final selectors = <Selector>[];
    for (Candidate? c = target; c != null; c = c.parent) {
      if (c.node.key != null) selectors.add(Selector(id: c.node.key));
      if (c.node.semanticsId != null) selectors.add(Selector(id: c.node.semanticsId));
      if (identical(c, target) && c.node.text != null) selectors.add(Selector(text: c.node.text));
    }
    // Index into the same collapsed set QaFinder.find would return for this
    // type, not the raw candidate list: find() drops a match that has a
    // same-type descendant match, so raw positions can point at the wrong
    // node (or a selector find() then rejects as ambiguous/not_found).
    final collapsed = QaFinder.find(Selector(type: target.node.type));
    final typeIndex = collapsed.indexWhere((c) => identical(c.element, target.element));
    if (typeIndex != -1) {
      selectors.add(Selector(type: target.node.type, index: typeIndex));
    }
    return {
      'node': reported.node.toJson(),
      'selectors': [for (final s in selectors) s.toJson()],
    };
  }

  /// Climbs from [c] past controls that are another control's internals: an
  /// interactive node with no text, key or semantics of its own that covers
  /// exactly the visible rect of the nearest enclosing interactive hit (the
  /// Scrollable an EditableText builds, a GestureDetector filling another).
  /// The mirror ranks by smallest visible area and keeps the outer node on a
  /// tie; deferring here keeps the reported node the one it outlines.
  static Candidate _outermostSameControl(Candidate c, bool Function(Candidate) isHit) {
    var current = c;
    while (_isBareControl(current.node)) {
      Candidate? outer;
      for (var p = current.parent; p != null; p = p.parent) {
        if (isHit(p) && p.node.interactive) {
          outer = p;
          break;
        }
      }
      if (outer == null || outer.visibleRect == null || outer.visibleRect != current.visibleRect) break;
      current = outer;
    }
    return current;
  }

  static bool _isBareControl(QaNode n) =>
      n.interactive && n.text == null && n.key == null && n.semanticsId == null && n.label == null;
}
