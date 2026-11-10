import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import 'args.dart';

/// The clip rect a subtree is drawn within, and which view it belongs to.
/// Reset at each RenderView boundary and narrowed by every ancestor
/// [RenderAbstractViewport] (ListView, SingleChildScrollView, ...).
typedef _Clip = ({ui.Rect rect, int viewId});

/// The nearest ancestor widget that could itself be a text source, used to
/// decide whether a RichText's text belongs to an enclosing Text.
enum _TextSource { text, richText }

/// One element visited during a walk, with its geometry and QaNode view.
class Candidate {
  Candidate({
    required this.element,
    required this.box,
    required this.rect,
    required this.visibleRect,
    required this.viewId,
    required this.parent,
    required this.node,
  });

  final Element element;
  final RenderBox? box;
  final ui.Rect? rect;

  /// The element's global rect intersected with its RenderView's bounds and
  /// with the global bounds of every ancestor RenderAbstractViewport. Null
  /// when nothing of the element is visible (or it has no box). This is the
  /// rect to act on, per spec 4.4 (act on the centre of the visible rect).
  final ui.Rect? visibleRect;
  final int viewId;
  final Candidate? parent;
  final QaNode node;

  bool get interesting =>
      node.text != null || node.key != null || node.semanticsId != null || node.label != null || node.interactive;

  bool isDescendantOf(Candidate other) {
    for (var p = parent; p != null; p = p.parent) {
      if (identical(p, other)) return true;
    }
    return false;
  }

  Candidate? get nearestInterestingAncestor {
    for (var p = parent; p != null; p = p.parent) {
      if (p.interesting) return p;
    }
    return null;
  }
}

class QaFinder {
  /// Walks every onstage element from the root and returns them in tree order.
  static List<Candidate> collect() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      throw QaException(QaErrorCode.notReady, 'the widget tree has no root element yet');
    }
    final out = <Candidate>[];
    var nextId = 0;

    void visit(Element element, Candidate? parent, _Clip? clip) {
      final widget = element.widget;
      final renderObject = element.renderObject;
      final box = renderObject is RenderBox && renderObject.attached && renderObject.hasSize ? renderObject : null;
      ui.Rect? rect;
      ui.Rect? visibleRect;
      var viewId = parent?.viewId ?? 0;
      var childClip = clip;
      if (box != null) {
        final view = viewOf(box);
        viewId = view.flutterView.viewId;
        rect = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
        // A clip carried from a different view (or no clip yet) does not
        // apply here; start fresh at this view's own bounds.
        final activeClip = clip != null && clip.viewId == viewId ? clip.rect : Offset.zero & view.size;
        final intersected = rect.intersect(activeClip);
        visibleRect = intersected.width > 0 && intersected.height > 0 ? intersected : null;
        final nextClipRect = box is RenderAbstractViewport ? activeClip.intersect(rect) : activeClip;
        childClip = (rect: nextClipRect, viewId: viewId);
      }
      final (interactive, enabled) = _interactivity(widget);
      final candidate = Candidate(
        element: element,
        box: box,
        rect: rect,
        visibleRect: visibleRect,
        viewId: viewId,
        parent: parent,
        node: QaNode(
          nodeId: nextId++,
          parentId: null, // filled in by Snapshot for the elements output
          type: widget.runtimeType.toString(),
          text: _textOf(widget, parent),
          key: _keyOf(widget),
          semanticsId: widget is Semantics ? _nonEmpty(widget.properties.identifier) : null,
          label: widget is Semantics ? _nonEmpty(widget.properties.label) : null,
          rect: rect == null ? null : QaRect(rect.left, rect.top, rect.width, rect.height),
          viewId: viewId,
          visible: visibleRect != null,
          interactive: interactive,
          enabled: enabled,
          visibleRect: visibleRect == null
              ? null
              : QaRect(visibleRect.left, visibleRect.top, visibleRect.width, visibleRect.height),
        ),
      );
      out.add(candidate);
      element.debugVisitOnstageChildren((child) => visit(child, candidate, childClip));
    }

    visit(root, null, null);
    return out;
  }

  static RenderView viewOf(RenderObject object) {
    RenderObject? current = object;
    while (current != null && current is! RenderView) {
      current = current.parent;
    }
    if (current == null) {
      throw QaException(QaErrorCode.internal, 'render object is not attached to a RenderView');
    }
    return current as RenderView;
  }

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

  static String? _keyOf(Widget widget) {
    final key = widget.key;
    return key is ValueKey<String> ? key.value : null;
  }

  static String? _textOf(Widget widget, Candidate? parent) {
    if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
    if (widget is RichText) {
      // Text's build() produces a RichText through intermediate wrapper
      // widgets (a MouseRegion/SelectionContainer chain under a
      // SelectionRegistrar, or Semantics/ExcludeSemantics with
      // semanticsLabel), so the immediate parent widget is never literally
      // Text. Walk up to the nearest ancestor that is itself a text source:
      // if it's a Text, this RichText is that Text's own rendering and must
      // not also report text (avoiding a duplicate text-bearing node that
      // would defeat innermost-collapse for a plain text selector); if it's
      // another RichText (e.g. this one sits inside a WidgetSpan), this
      // RichText is independent of any farther-out Text and keeps its text.
      if (_nearestAncestorTextSource(parent) == _TextSource.text) return null;
      return widget.text.toPlainText();
    }
    // An obscured field (a password) reports no text, so its value never
    // reaches element dumps, the studio's inspector or a text selector.
    if (widget is EditableText) return widget.obscureText ? null : widget.controller.text;
    if (widget is Tooltip) return widget.message;
    return null;
  }

  static _TextSource? _nearestAncestorTextSource(Candidate? parent) {
    for (var p = parent; p != null; p = p.parent) {
      final w = p.element.widget;
      if (w is Text) return _TextSource.text;
      if (w is RichText) return _TextSource.richText;
    }
    return null;
  }

  static (bool, bool) _interactivity(Widget w) {
    if (w is ButtonStyleButton) return (true, w.enabled);
    if (w is IconButton) return (true, w.onPressed != null);
    if (w is InkResponse) return (true, w.onTap != null || w.onLongPress != null || w.onDoubleTap != null);
    if (w is GestureDetector) return (true, true);
    if (w is EditableText) return (true, !w.readOnly);
    if (w is Checkbox) return (true, w.onChanged != null);
    if (w is Switch) return (true, w.onChanged != null);
    if (w is Slider) return (true, w.onChanged != null);
    if (w is ListTile) return (true, w.enabled);
    if (w is Scrollable) return (true, true);
    return (false, true);
  }

  static bool matches(Candidate c, Selector s) {
    final n = c.node;
    if (s.text != null && n.text?.trim() != s.text) return false;
    if (s.textRegex != null) {
      final text = n.text;
      if (text == null || !RegExp('^(?:${s.textRegex})\$').hasMatch(text)) return false;
    }
    if (s.id != null && n.key != s.id && n.semanticsId != s.id) return false;
    if (s.key != null && n.key != s.key) return false;
    if (s.semanticsId != null && n.semanticsId != s.semanticsId) return false;
    if (s.type != null && n.type != s.type) return false;
    if (s.enabled != null && n.enabled != s.enabled) return false;
    if (s.within != null) {
      var ok = false;
      for (var p = c.parent; p != null; p = p.parent) {
        if (matches(p, s.within!)) {
          ok = true;
          break;
        }
      }
      if (!ok) return false;
    }
    return true;
  }

  /// All matches in tree order, collapsed to innermost when matches nest,
  /// then narrowed by `index` when given.
  static List<Candidate> find(Selector selector) {
    if (selector.isEmpty) throw badRequest('selector has no fields');
    final all = collect();
    var hits = all.where((c) => matches(c, selector)).toList();
    hits = hits.where((h) => !hits.any((o) => !identical(o, h) && o.isDescendantOf(h))).toList();
    final index = selector.index;
    if (index != null) {
      if (index < 0 || index >= hits.length) {
        throw QaException(
          QaErrorCode.notFound,
          'index $index out of range, ${hits.length} match(es) for $selector',
          details: {'count': hits.length, 'selector': selector.toJson()},
        );
      }
      hits = [hits[index]];
    }
    return hits;
  }

  /// The point a pointer action should hit, after checking the target is on
  /// screen, not covered, and enabled. Acts on the centre of the candidate's
  /// visible rect (spec 4.4), so a target scrolled partly under an app bar
  /// or clipped by a viewport is tapped in its unobstructed part.
  static Offset actionPoint(Candidate c) {
    final box = c.box;
    if (box == null) {
      throw QaException(QaErrorCode.notReady, '${c.node.type} has no laid-out render box');
    }
    final visibleRect = c.visibleRect;
    if (visibleRect == null) {
      final view = viewOf(box);
      throw QaException(
        QaErrorCode.offScreen,
        '${c.node} is outside the visible view',
        details: {
          'rect': c.node.rect?.toJson(),
          'visibleRect': null,
          'view': {'width': view.size.width, 'height': view.size.height},
        },
      );
    }
    final point = visibleRect.center;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, point, c.viewId);
    final hit = result.path.any((entry) {
      final target = entry.target;
      return target is RenderObject && _isSelfOrDescendant(target, box);
    });
    if (!hit) {
      final top = result.path.isEmpty ? null : result.path.first.target.runtimeType.toString();
      throw QaException(
        QaErrorCode.obscured,
        '${c.node} is covered at ${point.dx.toStringAsFixed(1)},${point.dy.toStringAsFixed(1)} by $top',
        details: {
          'point': {'x': point.dx, 'y': point.dy},
          'topmost': top,
        },
      );
    }
    if (c.node.interactive && !c.node.enabled) {
      throw QaException(QaErrorCode.notReady, '${c.node} is disabled');
    }
    return point;
  }

  static bool _isSelfOrDescendant(RenderObject target, RenderObject ancestor) {
    RenderObject? current = target;
    while (current != null) {
      if (identical(current, ancestor)) return true;
      current = current.parent;
    }
    return false;
  }

  static Candidate resolveOne(Selector selector) {
    final hits = find(selector);
    if (hits.isEmpty) {
      throw QaException(QaErrorCode.notFound, 'nothing matches $selector', details: {'selector': selector.toJson()});
    }
    if (hits.length > 1) {
      throw QaException(
        QaErrorCode.ambiguous,
        '${hits.length} widgets match $selector; add index or narrow the selector',
        details: {
          'count': hits.length,
          'selector': selector.toJson(),
          'nodes': [for (final h in hits.take(5)) h.node.toJson()],
        },
      );
    }
    return hits.single;
  }
}
