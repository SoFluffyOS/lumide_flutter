import 'package:lumide_flutter/src/services/lcov_parser.dart';
import 'package:test/test.dart';

void main() {
  test('reads covered and uncovered lines per file', () {
    final files = parseLcov('''
SF:lib/math.dart
DA:1,3
DA:2,0
DA:4,1
LF:3
LH:2
end_of_record
SF:/abs/lib/other.dart
DA:7,0
end_of_record
''', projectRoot: '/project');

    expect(files.map((file) => file.uri), [
      'file:///project/lib/math.dart',
      'file:///abs/lib/other.dart',
    ]);
    expect(files.first.coveredLines, [1, 4]);
    expect(files.first.uncoveredLines, [2]);
    expect(files.last.uncoveredLines, [7]);
  });

  test('ignores malformed lines and records without a file', () {
    expect(parseLcov('DA:x,1\nend_of_record\n', projectRoot: '/p'), isEmpty);
  });
}
