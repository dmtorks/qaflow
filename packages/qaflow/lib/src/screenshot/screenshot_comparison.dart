enum BaselineMode { record, strict, update }

enum ComparisonOutcome { passed, failed, recorded, updated }

class ScreenshotComparison {
  const ScreenshotComparison({
    required this.name,
    required this.baselinePath,
    required this.deviceKey,
    required this.outcome,
    required this.threshold,
    required this.actual,
    this.mismatchPercent,
    this.baseline,
    this.diff,
  });

  factory ScreenshotComparison.fromJson(Map<String, Object?> j) => ScreenshotComparison(
    name: j['name'] as String,
    baselinePath: j['baselinePath'] as String,
    deviceKey: j['deviceKey'] as String,
    outcome: ComparisonOutcome.values.byName(j['outcome'] as String),
    threshold: (j['threshold'] as num).toDouble(),
    actual: j['actual'] as String,
    mismatchPercent: (j['mismatchPercent'] as num?)?.toDouble(),
    baseline: j['baseline'] as String?,
    diff: j['diff'] as String?,
  );

  final String name;

  /// Relative to the app root.
  final String baselinePath;
  final String deviceKey;
  final ComparisonOutcome outcome;
  final double? mismatchPercent;
  final double threshold;

  /// Artifacts, relative to the run folder.
  final String actual;
  final String? baseline;
  final String? diff;

  Map<String, Object?> toJson() => {
    'name': name,
    'baselinePath': baselinePath,
    'deviceKey': deviceKey,
    'outcome': outcome.name,
    if (mismatchPercent != null) 'mismatchPercent': mismatchPercent,
    'threshold': threshold,
    'actual': actual,
    if (baseline != null) 'baseline': baseline,
    if (diff != null) 'diff': diff,
  };
}
