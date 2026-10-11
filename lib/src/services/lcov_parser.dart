import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

/// Files reported from one coverage run; larger reports are cut off.
const maxCoverageFiles = 5000;

/// Line coverage from an `lcov.info` report, as written by
/// `flutter test --coverage`. Relative paths are resolved against
/// [projectRoot].
List<LumideFileCoverage> parseLcov(String report,
    {required String projectRoot}) {
  final files = <LumideFileCoverage>[];
  String? sourcePath;
  var covered = <int>[];
  var uncovered = <int>[];
  for (final rawLine in report.split('\n')) {
    final line = rawLine.trim();
    if (line.startsWith('SF:')) {
      sourcePath = line.substring(3);
      covered = [];
      uncovered = [];
      continue;
    }
    if (line.startsWith('DA:')) {
      final [lineNumber, hits, ...] = '${line.substring(3)},'.split(',');
      final number = int.tryParse(lineNumber);
      final count = int.tryParse(hits);
      if (number == null || count == null) continue;
      switch (count > 0) {
        case true:
          covered.add(number);
        case false:
          uncovered.add(number);
      }
      continue;
    }
    if (line != 'end_of_record') continue;
    final file = sourcePath;
    sourcePath = null;
    if (file == null) continue;
    files.add(
      LumideFileCoverage(
        uri: Uri.file(switch (path.isAbsolute(file)) {
          true => file,
          false => path.join(projectRoot, file),
        })
            .toString(),
        coveredLines: covered,
        uncoveredLines: uncovered,
      ),
    );
    if (files.length >= maxCoverageFiles) break;
  }
  return files;
}
