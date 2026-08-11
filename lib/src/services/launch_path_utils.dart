import 'package:path/path.dart' as path;

String normalizeLaunchPath(
  String value, {
  path.Context? pathContext,
}) {
  return (pathContext ?? path.context).normalize(value);
}
