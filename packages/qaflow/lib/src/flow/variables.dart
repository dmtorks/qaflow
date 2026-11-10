class UndefinedVariableException implements Exception {
  UndefinedVariableException(this.name);
  final String name;
  @override
  String toString() => 'undefined variable $name';
}

/// `${NAME}` substitution. Lookup walks from this scope to its parents, so
/// the innermost definition wins.
class VariableScope {
  VariableScope([Map<String, String> values = const {}, this.parent]) : _values = Map.unmodifiable(values);

  final Map<String, String> _values;
  final VariableScope? parent;

  static final RegExp reference = RegExp(r'\$\{([^}]*)\}');
  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  VariableScope child(Map<String, String> values) => VariableScope(values, this);

  String? lookup(String name) => _values[name] ?? parent?.lookup(name);

  String substitute(String input) => input.replaceAllMapped(reference, (m) {
    final name = m[1]!;
    return lookup(name) ?? (throw UndefinedVariableException(name));
  });

  /// Contents of `${...}` that are not plain names; Maestro would evaluate
  /// them as JavaScript, which this runner does not support.
  static List<String> invalidReferences(String input) => [
    for (final m in reference.allMatches(input))
      if (!_identifier.hasMatch(m[1]!)) m[1]!,
  ];

  static bool hasReferences(String input) => reference.hasMatch(input);

  /// Parses `KEY=VALUE` strings from the command line.
  static Map<String, String> parseAssignments(List<String> assignments) {
    final out = <String, String>{};
    for (final a in assignments) {
      final eq = a.indexOf('=');
      if (eq <= 0) throw FormatException('expected KEY=VALUE, got "$a"');
      final key = a.substring(0, eq);
      if (!_identifier.hasMatch(key)) throw FormatException('invalid variable name "$key"');
      out[key] = a.substring(eq + 1);
    }
    return out;
  }
}
