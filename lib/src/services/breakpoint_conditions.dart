/// Whether a breakpoint pause should be skipped: every breakpoint that was
/// hit has a condition, and each one evaluated to false.
///
/// [evaluate] returns null when an expression cannot be evaluated; the pause
/// is then kept so the user notices the broken condition.
Future<bool> shouldSkipConditionalPause({
  required List<String?> conditions,
  required Future<bool?> Function(String expression) evaluate,
}) async {
  if (conditions.isEmpty) return false;
  for (final condition in conditions) {
    if (condition == null || condition.trim().isEmpty) return false;
    final result = await evaluate(condition);
    if (result != false) return false;
  }
  return true;
}
