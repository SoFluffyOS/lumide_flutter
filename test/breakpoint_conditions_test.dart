import 'package:lumide_flutter/src/services/breakpoint_conditions.dart';
import 'package:test/test.dart';

void main() {
  Future<bool?> Function(String) results(Map<String, bool?> values) =>
      (expression) async => values[expression];

  HitBreakpoint breakpoint([String? condition]) =>
      (condition: condition, logMessage: null);

  HitBreakpoint logpoint(String message, [String? condition]) =>
      (condition: condition, logMessage: message);

  group('decideBreakpointPause', () {
    test('resumes only when every hit condition is false', () async {
      final allFalse = await decideBreakpointPause(
        breakpoints: [breakpoint('a'), breakpoint('b')],
        evaluate: results({'a': false, 'b': false}),
      );
      expect(allFalse.resume, isTrue);

      final oneTrue = await decideBreakpointPause(
        breakpoints: [breakpoint('a'), breakpoint('b')],
        evaluate: results({'a': false, 'b': true}),
      );
      expect(oneTrue.resume, isFalse);
    });

    test('stops for unconditional breakpoints and broken conditions', () async {
      final unconditional = await decideBreakpointPause(
        breakpoints: [breakpoint('a'), breakpoint()],
        evaluate: results({'a': false}),
      );
      expect(unconditional.resume, isFalse);

      final broken = await decideBreakpointPause(
        breakpoints: [breakpoint('broken')],
        evaluate: results({'broken': null}),
      );
      expect(broken.resume, isFalse);

      final blank = await decideBreakpointPause(
        breakpoints: [breakpoint('  ')],
        evaluate: results({}),
      );
      expect(blank.resume, isFalse);

      final none = await decideBreakpointPause(
        breakpoints: const [],
        evaluate: results({}),
      );
      expect(none.resume, isFalse);
    });

    test('logpoints print and resume', () async {
      final decision = await decideBreakpointPause(
        breakpoints: [logpoint('x = {x}')],
        evaluate: results({}),
      );
      expect(decision.resume, isTrue);
      expect(decision.logMessages, ['x = {x}']);
    });

    test('logpoints respect their condition', () async {
      final decision = await decideBreakpointPause(
        breakpoints: [logpoint('hit', 'a'), logpoint('skip', 'b')],
        evaluate: results({'a': true, 'b': false}),
      );
      expect(decision.resume, isTrue);
      expect(decision.logMessages, ['hit']);
    });

    test('a plain breakpoint on the same line still stops', () async {
      final decision = await decideBreakpointPause(
        breakpoints: [logpoint('hit'), breakpoint()],
        evaluate: results({}),
      );
      expect(decision.resume, isFalse);
      expect(decision.logMessages, ['hit']);
    });

    test('a logpoint with a broken condition stops', () async {
      final decision = await decideBreakpointPause(
        breakpoints: [logpoint('hit', 'broken')],
        evaluate: results({'broken': null}),
      );
      expect(decision.resume, isFalse);
      expect(decision.logMessages, isEmpty);
    });
  });

  group('formatLogMessage', () {
    Future<String?> Function(String) values(Map<String, String?> map) =>
        (expression) async => map[expression];

    test('expands placeholders', () async {
      expect(
        await formatLogMessage('a={a}, b={ b }', values({'a': '1', 'b': '2'})),
        'a=1, b=2',
      );
    });

    test('supports nested braces', () async {
      expect(
        await formatLogMessage(
          'n={items.where((i) { return i > 0; }).length}',
          values({'items.where((i) { return i > 0; }).length': '3'}),
        ),
        'n=3',
      );
    });

    test('shows failed expressions and keeps unclosed braces', () async {
      expect(await formatLogMessage('{oops}', values({})), '<error>');
      expect(
          await formatLogMessage('open { brace', values({})), 'open { brace');
      expect(await formatLogMessage('plain', values({})), 'plain');
      expect(await formatLogMessage('{}', values({})), '{}');
    });
  });
}
