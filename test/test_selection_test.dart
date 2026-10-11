import 'package:lumide_flutter/src/services/test_selection.dart';
import 'package:test/test.dart';

void main() {
  group('testNamePattern', () {
    test('matches a test by its full name only', () {
      final pattern = RegExp(testNamePattern('adds', includeChildren: false));

      expect(pattern.hasMatch('adds'), isTrue);
      expect(pattern.hasMatch('adds one'), isFalse);
      expect(pattern.hasMatch('Counter adds'), isFalse);
    });

    test('matches a group and the tests inside it', () {
      final pattern = RegExp(testNamePattern('Counter', includeChildren: true));

      expect(pattern.hasMatch('Counter'), isTrue);
      expect(pattern.hasMatch('Counter adds'), isTrue);
      expect(pattern.hasMatch('Counter2 adds'), isFalse);
      expect(pattern.hasMatch('My Counter adds'), isFalse);
    });

    test('escapes regular expression characters', () {
      const name = r'parses (a|b)* [x] $1.0 ^ok? {2} \d+';
      final pattern = RegExp(testNamePattern(name, includeChildren: false));

      expect(pattern.hasMatch(name), isTrue);
      expect(pattern.hasMatch('parses a* [x] \$1.0 ^ok? {2} \\d+'), isFalse);
    });
  });

  group('invocationFor', () {
    const file = '/project/test/counter_test.dart';
    const other = '/project/test/other_test.dart';

    test('runs one test with an exact pattern', () {
      final invocation = invocationFor(
        const [TestTarget.test(file, 'Counter adds')],
      );

      expect(invocation.files, [file]);
      expect(invocation.namePattern, r'^Counter adds$');
    });

    test('combines tests and groups into one alternation', () {
      final invocation = invocationFor(const [
        TestTarget.test(file, 'Counter adds'),
        TestTarget.group(file, 'Counter edge'),
        TestTarget.test(other, 'loads'),
        TestTarget.test(file, 'Counter adds'),
      ]);
      final pattern = RegExp(invocation.namePattern ?? '');

      expect(invocation.files, [file, other]);
      expect(pattern.hasMatch('Counter adds'), isTrue);
      expect(pattern.hasMatch('Counter edge zero'), isTrue);
      expect(pattern.hasMatch('loads'), isTrue);
      expect(pattern.hasMatch('Counter adds one'), isFalse);
      expect(pattern.hasMatch('Counter subtracts'), isFalse);
    });

    test('a whole suite runs its files without a name filter', () {
      final invocation = invocationFor(const [
        TestTarget.suite(file),
        TestTarget.test(other, 'loads'),
      ]);

      expect(invocation.files, [file, other]);
      expect(invocation.namePattern, isNull);
    });

    test('arguments put the pattern first and files relative to the root', () {
      const invocation = TestInvocation(
        files: [file, '/elsewhere/a_test.dart'],
        namePattern: r'^a$',
      );

      expect(invocation.arguments('/project'), [
        '--name',
        r'^a$',
        'test/counter_test.dart',
        '/elsewhere/a_test.dart',
      ]);
    });
  });
}
