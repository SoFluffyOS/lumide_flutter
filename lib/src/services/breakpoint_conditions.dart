/// A breakpoint the VM paused on, with the user's settings.
typedef HitBreakpoint = ({String? condition, String? logMessage});

/// What to do after a breakpoint pause.
typedef BreakpointPauseDecision = ({bool resume, List<String> logMessages});

/// Decides whether a breakpoint pause should stop, and which logpoint
/// messages to print. The VM has neither conditions nor logpoints, so both
/// are applied on pause.
///
/// A breakpoint applies when it has no condition or its condition is true.
/// Logpoints that apply print their message and never stop. The pause is kept
/// when any plain breakpoint applies, or when a condition cannot be evaluated
/// ([evaluate] returns null), so the user notices the broken condition.
Future<BreakpointPauseDecision> decideBreakpointPause({
  required List<HitBreakpoint> breakpoints,
  required Future<bool?> Function(String expression) evaluate,
}) async {
  if (breakpoints.isEmpty) return (resume: false, logMessages: <String>[]);

  var shouldStop = false;
  final logMessages = <String>[];
  for (final breakpoint in breakpoints) {
    final condition = breakpoint.condition?.trim() ?? '';
    final applies = switch (condition.isEmpty) {
      true => true,
      false => await evaluate(condition),
    };
    final logMessage = breakpoint.logMessage ?? '';
    final isLogpoint = logMessage.trim().isNotEmpty;
    if (applies == null) {
      shouldStop = true;
      continue;
    }
    if (!applies) continue;
    if (isLogpoint) {
      logMessages.add(logMessage);
      continue;
    }
    shouldStop = true;
  }
  return (resume: !shouldStop, logMessages: logMessages);
}

/// Expands `{expression}` placeholders in a logpoint [template].
///
/// [evaluate] returns the expression's text, or null when it fails; failed
/// expressions are shown as `<error>`. Braces nest, so `{map['a']}` and
/// `{items.where((i) => i > 0)}` work. An unclosed `{` is kept as text.
Future<String> formatLogMessage(
  String template,
  Future<String?> Function(String expression) evaluate,
) async {
  final output = StringBuffer();
  var index = 0;
  while (index < template.length) {
    final open = template.indexOf('{', index);
    if (open < 0) break;
    final close = _matchingBrace(template, open);
    if (close < 0) break;

    output.write(template.substring(index, open));
    final expression = template.substring(open + 1, close).trim();
    final value = switch (expression.isEmpty) {
      true => '{}',
      false => await evaluate(expression) ?? '<error>',
    };
    output.write(value);
    index = close + 1;
  }
  output.write(template.substring(index));
  return output.toString();
}

int _matchingBrace(String text, int open) {
  var depth = 0;
  for (var index = open; index < text.length; index++) {
    final char = text[index];
    if (char == '{') depth++;
    if (char != '}') continue;
    depth--;
    if (depth == 0) return index;
  }
  return -1;
}
