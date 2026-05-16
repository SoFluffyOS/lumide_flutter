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

  final List<String> _cachedProjects = [];
  bool _projectsLoaded = false;

  final List<String> _cachedTargets = [];
  bool _targetsLoaded = false;

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
  Future<List<String>> findAllProjects({bool forceRefresh = false}) async {
    if (_projectsLoaded && !forceRefresh) return _cachedProjects;

    final pubspecUris = await context.workspace.findFiles('**/pubspec.yaml');
    if (pubspecUris.isEmpty) {
      _cachedProjects.clear();
      _projectsLoaded = true;
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

    _cachedProjects.clear();
    _cachedProjects.addAll(projects);
    _projectsLoaded = true;
    return _cachedProjects;
  }

  /// Scans the workspace to find all `main.dart` files.
  /// Returns a list of absolute paths to the entry points, omitting build/cache folders.
  Future<List<String>> findAllTargets({bool forceRefresh = false}) async {
    if (_targetsLoaded && !forceRefresh) return _cachedTargets;

    final mainDartFiles = await context.workspace.findFiles('**/main.dart');
    _cachedTargets.clear();

    for (final uri in mainDartFiles) {
      final parsed = Uri.parse(uri);
      final absolutePath = parsed.toRealPath();

      // Skip cache, build, hidden, and generated platform directories.
      // Note: startsWith('.') already covers .dart_tool, .fvm, .symlinks,
      // .plugin_symlinks, etc.
      final parts = path.split(absolutePath);
      if (parts.any((part) =>
          part.startsWith('.') ||
          part == 'build' ||
          part == 'ephemeral')) {
        continue;
      }

      _cachedTargets.add(absolutePath);
    }

    _targetsLoaded = true;
    return _cachedTargets;
  }
}
