import 'package:lumide_api/lumide_api.dart';

class ProjectService {
  final LumideContext context;

  ProjectService(this.context);

  /// Returns the root path of the Flutter project for the given [uri].
  /// If [uri] is null, uses the active document.
  /// Traverses up from the file path to find a pubspec.yaml.
  Future<String?> getProjectRoot([String? uri]) async {
    String? targetUri = uri;
    targetUri ??= await context.editor.getActiveDocumentUri();

    if (targetUri == null) {
      return null;
    }

    // Simple traversal
    // Uri is like file:///path/to/project/lib/main.dart
    // We need to strip scheme and traverse up.

    String path = Uri.parse(targetUri).path;

    // Guard against infinite loop
    int maxDepth = 20;
    while (path.length > 1 && maxDepth > 0) {
      final pubspecPath = '$path/pubspec.yaml';
      if (await context.fs.exists(pubspecPath)) {
        return path;
      }

      // Go up one level
      final parent = Uri.parse(path).pathSegments.isEmpty
          ? '/'
          : path.substring(0, path.lastIndexOf('/'));

      if (parent == path) break; // Reached root
      path = parent;
      if (path.isEmpty) path = '/'; // Handle root

      maxDepth--;
    }

    return null;
  }

  /// Scans the workspace to find all folders containing a `pubspec.yaml`.
  /// Returns a list of paths to project roots.
  Future<List<String>> findAllProjects() async {
    // We assume the workspace root is available via some mechanism,
    // or we can try to find it from the active document.

    // Workaround: We will rely on `.` (current working directory of the plugin process)
    // which is usually the workspace root when spawned by the IDE.
    const root = '.';
    final projects = <String>[];
    await _scanForPubspec(root, projects, 0);
    return projects;
  }

  Future<void> _scanForPubspec(
      String dirPath, List<String> projects, int depth) async {
    if (depth > 5) return; // Max depth to avoid performance issues

    try {
      final entries = await context.fs.list(dirPath);
      bool hasPubspec = false;
      final subdirs = <String>[];

      for (final entry in entries) {
        if (entry.endsWith('pubspec.yaml')) {
          hasPubspec = true;
        } else {
          // Basic check if it's a directory (no extension or known dir)
          // context.fs.list return full paths.
          // We'll rely on FS check or just try to list it.
          // Optimization: skip hidden folders and build folders
          final name = Uri.parse(entry).pathSegments.last;
          if (!name.startsWith('.') &&
              name != 'build' &&
              name != 'ios' &&
              name != 'android' &&
              name != 'macos' &&
              name != 'windows' &&
              name != 'linux' &&
              name != 'web') {
            // It's a candidate for recursion, but `fs.list` returns files too.
            // We will verify later if we can list it.
            subdirs.add(entry);
          }
        }
      }

      if (hasPubspec) {
        projects.add(dirPath);
      }

      for (final subdir in subdirs) {
        // Recurse into subdirectories

        await _scanForPubspec(subdir, projects, depth + 1);
      }
    } catch (e) {
      // Not a directory or permission denied
    }
  }
}
