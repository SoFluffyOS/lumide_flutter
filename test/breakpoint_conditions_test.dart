import 'package:lumide_flutter/src/services/breakpoint_conditions.dart';
import 'package:test/test.dart';

void main() {
  Future<bool?> Function(String) results(Map<String, bool?> values) =>
      (expression) async => values[expression];

  test('skips only when every hit condition is false', () async {
    expect(
      await shouldSkipConditionalPause(
        conditions: ['a', 'b'],
        evaluate: results({'a': false, 'b': false}),
      ),
      isTrue,
    );
    expect(
      await shouldSkipConditionalPause(
        conditions: ['a', 'b'],
        evaluate: results({'a': false, 'b': true}),
      ),
      isFalse,
    );
  });

  test('stops for unconditional breakpoints and broken conditions', () async {
    var evaluations = 0;
    expect(
      await shouldSkipConditionalPause(
        conditions: ['a', null],
        evaluate: (expression) async {
          evaluations++;
          return false;
        },
      ),
      isFalse,
    );
    expect(evaluations, 1);
    expect(
      await shouldSkipConditionalPause(
        conditions: ['broken'],
        evaluate: results({'broken': null}),
      ),
      isFalse,
    );
    expect(
      await shouldSkipConditionalPause(
        conditions: const [],
        evaluate: results({}),
      ),
      isFalse,
    );
    expect(
      await shouldSkipConditionalPause(
        conditions: ['  '],
        evaluate: results({}),
      ),
      isFalse,
    );
  });
}
