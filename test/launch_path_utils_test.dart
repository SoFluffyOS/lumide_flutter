import 'package:lumide_flutter/src/services/launch_path_utils.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('normalizes mixed Windows path separators', () {
    expect(
      normalizeLaunchPath(
        r'D:\sinan/apps/sinan/lib/main.dart',
        pathContext: path.windows,
      ),
      r'D:\sinan\apps\sinan\lib\main.dart',
    );
  });
}
