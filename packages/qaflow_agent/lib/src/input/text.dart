import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';

import '../finder.dart';
import '../frames.dart';

class TextSynth {
  /// The EditableText that owns the primary focus, if any.
  static EditableTextState? focusedEditable() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }
    return context.findAncestorStateOfType<EditableTextState>();
  }

  /// Resolves a selector to the candidate that matched it and the
  /// EditableText inside the matched widget (a TextField wraps one), and
  /// focuses it. Without a selector, uses the focused field and returns a
  /// null candidate. Callers that go on to mutate the field's text must
  /// resolve before mutating: a text selector that matches the field's
  /// current content stops matching once the text changes, so resolving
  /// again afterwards would spuriously report not_found.
  static Future<(Candidate?, EditableTextState)> resolve(Selector? selector) async {
    if (selector == null) {
      final state = focusedEditable();
      if (state == null) {
        throw QaException(QaErrorCode.notReady, 'no text field has focus; pass a selector or tap a field first');
      }
      if (state.widget.readOnly) {
        throw QaException(QaErrorCode.notReady, 'the focused field is read-only or disabled');
      }
      return (null, state);
    }
    final candidate = QaFinder.resolveOne(selector);
    QaFinder.actionPoint(candidate);
    final state = editableIn(candidate.element);
    if (state == null) {
      throw QaException(QaErrorCode.notFound, '${candidate.node} contains no EditableText');
    }
    if (state.widget.readOnly) {
      throw QaException(QaErrorCode.notReady, '${candidate.node} is read-only or disabled');
    }
    if (!state.widget.focusNode.hasFocus) {
      state.widget.focusNode.requestFocus();
      await Frames.next();
    }
    return (candidate, state);
  }

  static EditableTextState? editableIn(Element root) {
    EditableTextState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        found = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// What the desktop text input plugin does when Enter is pressed in a
  /// focused field: newline for multi-line fields, the input action otherwise.
  static void submit(EditableTextState state) {
    if (state.widget.maxLines != 1) {
      final value = state.textEditingValue;
      final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
      state.userUpdateTextEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(selection.start, selection.end, '\n'),
          selection: TextSelection.collapsed(offset: selection.start + 1),
        ),
        SelectionChangedCause.keyboard,
      );
    } else {
      state.performAction(state.widget.textInputAction ?? TextInputAction.done);
    }
  }

  static TextSelection _selectionOf(TextEditingValue value) =>
      value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);

  static String _apply(EditableTextState state, TextEditingValue next) {
    state.userUpdateTextEditingValue(next, SelectionChangedCause.keyboard);
    return state.textEditingValue.text;
  }

  /// Inserts [text] at the selection, replacing any selected range.
  static String enterText(EditableTextState state, String text) {
    final value = state.textEditingValue;
    final selection = _selectionOf(value);
    return _apply(
      state,
      TextEditingValue(
        text: value.text.replaceRange(selection.start, selection.end, text),
        selection: TextSelection.collapsed(offset: selection.start + text.length),
      ),
    );
  }

  /// Removes up to [count] characters before the cursor.
  static String eraseText(EditableTextState state, int count) {
    final value = state.textEditingValue;
    final selection = _selectionOf(value);
    final start = (selection.start - count).clamp(0, selection.start);
    return _apply(
      state,
      TextEditingValue(
        text: value.text.replaceRange(start, selection.end, ''),
        selection: TextSelection.collapsed(offset: start),
      ),
    );
  }

  static String setText(EditableTextState state, String text) => _apply(
    state,
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
}
