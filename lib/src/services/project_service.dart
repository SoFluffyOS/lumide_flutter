import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

extension UriExtension on Uri {
  String toRealPath() {
    if (Platform.isWindows) {
      final buffer = StringBuffer();
      if (authority.isNotEmpty) {
        buffer.write('\\\\$authority');
      }

      if (pathSegments.isEmpty && authority.isEmpty) {
        return '\\';
      }

      for (var i = 0; i < pathSegments.length; i++) {
        var segment = pathSegments[i];

        bool isDriveLetter = i == 0 &&
            segment.length == 2 &&
            segment[1] == ':' &&
            authority.isEmpty;

        if (!isDriveLetter) {
          buffer.write('\\');
        }
        buffer.write(segment);
      }

      final p = buffer.toString();

      // Ensure absolute path on Windows if missing drive letter
      if (p.startsWith('\\') && !p.contains(':')) {
        try {
          return File(p).absolute.path;
        } catch (_) {
          return p;
        }
      }

      return p;
    }
    return toFilePath();
  }
}

class ProjectService {
  final LumideContext context;

  ProjectService(this.context);

  /// Returns the root path of the Flutter project.
  /// Relies firmly on the host IDE workspace API.
  Future<String> getProjectRoot([String? uri]) async {
    final workspaceRootUri = await context.workspace.getRootUri();
    if (workspaceRootUri != null) {
      if (await context.fs
          .exists(path.join(workspaceRootUri, 'pubspec.yaml'))) {
        return workspaceRootUri;
      }
    }

    throw Exception(
        'Workspace root containing a pubspec.yaml is required to use the Flutter plugin.');
  }

  /// Scans the workspace to find all folders containing a `pubspec.yaml`.
  /// Returns a list of paths to project roots.
  Future<List<String>> findAllProjects() async {
    final pubspecUris = await context.workspace.findFiles('**/pubspec.yaml');
    if (pubspecUris.isEmpty) {
      return [];
    }

    final projects = pubspecUris
        .map((uri) {
          final parsed = Uri.parse(uri);
          final filePath = parsed.toRealPath();
          return path.dirname(filePath);
        })
        .toSet()
        .toList();

    return projects;
  }
}
