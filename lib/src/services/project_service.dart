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

  Future<String> getWorkspaceRoot() async {
    final workspaceRootUri = await context.workspace.getRootUri();
    if (workspaceRootUri == null || workspaceRootUri.isEmpty) {
      throw Exception(
          'Open a workspace folder before creating a Flutter project.');
    }
    return workspaceRootUri;
  }

  void clearCaches() {
    _cachedProjects.clear();
    _projectsLoaded = false;
    _cachedTargets.clear();
    _targetsLoaded = false;
  }

  /// Returns the root path of the Flutter project.
  /// Relies firmly on the host IDE workspace API.
  Future<String> getProjectRoot([String? uri]) async {
    final hintedPath = _pathFromUriOrPath(uri);
    if (hintedPath != null) {
      final hintedRoot = await findProjectRootForPath(hintedPath);
      if (hintedRoot != null) return hintedRoot;
    }

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

  Future<String?> findProjectRootForPath(String fileOrFolderPath) async {
    var current = fileOrFolderPath;
    final extension = path.extension(current);
    if (extension.isNotEmpty) {
      current = path.dirname(current);
    }

    final workspaceRoot = await context.workspace.getRootUri();
    final normalizedWorkspaceRoot =
        workspaceRoot == null ? null : path.normalize(workspaceRoot);

    while (true) {
      final pubspecPath = path.join(current, 'pubspec.yaml');
      if (await context.fs.exists(pubspecPath)) return current;

      final parent = path.dirname(current);
      if (parent == current) return null;
      if (normalizedWorkspaceRoot != null &&
          path.normalize(current) == normalizedWorkspaceRoot) {
        return null;
      }
      current = parent;
    }
  }

  String? _pathFromUriOrPath(String? uriOrPath) {
    if (uriOrPath == null || uriOrPath.isEmpty) return null;
    final parsed = Uri.tryParse(uriOrPath);
    if (parsed != null && parsed.isScheme('file')) {
      return parsed.toRealPath();
    }
    return uriOrPath;
  }

  String? pathFromMenuContext(Map<String, dynamic>? args) {
    final contextMap = _mapValue(args, 'context');
    if (contextMap == null) return null;

    final directFile = _mapValue(contextMap, 'file');
    if (_pathValue(directFile) case final filePath?) return filePath;

    final tab = _mapValue(contextMap, 'tab');
    final tabFile = _mapValue(tab, 'file');
    if (_pathValue(tabFile) case final tabPath?) return tabPath;

    final primary = _mapValue(contextMap, 'primary');
    if (_pathValue(primary) case final primaryPath?) return primaryPath;

    if (contextMap['selectedPaths'] case final List paths
        when paths.isNotEmpty) {
      final first = paths.first;
      if (first is String && first.isNotEmpty) return first;
    }

    final root = _mapValue(contextMap, 'root');
    return _pathValue(root);
  }

  String? folderFromMenuContext(Map<String, dynamic>? args) {
    final contextMap = _mapValue(args, 'context');
    if (contextMap == null) return null;

    final primary = _mapValue(contextMap, 'primary');
    final primaryPath = _pathValue(primary);
    if (primaryPath != null) {
      final type = primary?['type'];
      if (type == 'directory') return primaryPath;
      if (type == 'file') return path.dirname(primaryPath);
    }

    final contextPath = pathFromMenuContext(args);
    if (contextPath == null) return null;
    if (path.extension(contextPath).isNotEmpty) {
      return path.dirname(contextPath);
    }
    return contextPath;
  }

  Future<String?> projectRootFromMenuContext(
    Map<String, dynamic>? args,
  ) async {
    final contextPath = pathFromMenuContext(args);
    if (contextPath == null) return null;
    return findProjectRootForPath(contextPath);
  }

  Map<String, dynamic>? _mapValue(Map<dynamic, dynamic>? source, String key) {
    if (source == null) return null;
    final value = source[key];
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  String? _pathValue(Map<String, dynamic>? map) {
    if (map == null) return null;
    if (map['path'] case final String path when path.isNotEmpty) {
      return path;
    }
    if (map['uri'] case final String uri when uri.isNotEmpty) {
      return _pathFromUriOrPath(uri);
    }
    return null;
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
          part.startsWith('.') || part == 'build' || part == 'ephemeral')) {
        continue;
      }

      _cachedTargets.add(absolutePath);
    }

    _targetsLoaded = true;
    return _cachedTargets;
  }
}
