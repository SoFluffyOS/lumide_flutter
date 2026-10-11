import 'package:path/path.dart' as path;

/// A suite, group, or test that can be run again.
class TestTarget {
  const TestTarget.suite(this.file)
      : name = null,
        isGroup = false;

  const TestTarget.group(this.file, String this.name) : isGroup = true;

  const TestTarget.test(this.file, String this.name) : isGroup = false;

  /// Absolute path of the test file.
  final String file;

  /// Full name (enclosing group names and the test name, space separated),
  /// or null for a whole suite.
  final String? name;
  final bool isGroup;
}

/// What `flutter test` runs: files (none means the whole project) and an
/// optional `--name` pattern.
class TestInvocation {
  const TestInvocation({this.files = const [], this.namePattern});

  /// Absolute paths of test files or folders.
  final List<String> files;
  final String? namePattern;

  /// `flutter test` arguments, with [files] relative to [projectRoot] when
  /// they are inside it.
  List<String> arguments(String projectRoot) => [
        if (namePattern case final pattern?) ...['--name', pattern],
        for (final file in files)
          switch (path.isWithin(projectRoot, file)) {
            true => path.relative(file, from: projectRoot),
            false => file,
          },
      ];
}

/// A `--name` pattern matching exactly [fullName], plus the tests inside it
/// when [includeChildren] is true.
///
/// `flutter test --plain-name` matches substrings, so `adds` would also run
/// `adds one`. Anchoring an escaped regular expression matches the full name
/// instead; a group's tests are named `<group> <test>`, so groups match the
/// name followed by a space.
String testNamePattern(String fullName, {required bool includeChildren}) {
  final escaped = RegExp.escape(fullName);
  return switch (includeChildren) {
    true => '^$escaped( |\$)',
    false => '^$escaped\$',
  };
}

/// One `flutter test` invocation that runs every target.
///
/// Names are combined into one alternation, since `--name` given more than
/// once requires tests to match all of them. Selecting a whole suite runs
/// every selected file without a name filter, so the suite is not narrowed
/// by names picked from other files.
TestInvocation invocationFor(List<TestTarget> targets) {
  final files = <String>{for (final target in targets) target.file}.toList();
  final hasWholeSuite = targets.any((target) => target.name == null);
  if (hasWholeSuite) return TestInvocation(files: files);

  final patterns = <String>{
    for (final target in targets)
      if (target.name case final name?)
        testNamePattern(name, includeChildren: target.isGroup),
  }.toList();
  final pattern = switch (patterns.length) {
    0 => null,
    1 => patterns.single,
    _ => patterns.map((pattern) => '(?:$pattern)').join('|'),
  };
  return TestInvocation(files: files, namePattern: pattern);
}
