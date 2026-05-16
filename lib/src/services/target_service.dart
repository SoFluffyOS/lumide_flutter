import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:path/path.dart' as path;

class TargetService {
  final LumideContext context;
  final ProjectService projectService;

  String? _selectedTarget;
  bool _isLoading = false;

  TargetService(this.context, this.projectService);

  Future<String?> _getCachePath() async {
    try {
      final root = await projectService.getProjectRoot();
      return path.join(root, '.dart_tool', 'lumide', 'target.txt');
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadCache() async {
    final cachePath = await _getCachePath();
    if (cachePath != null && await context.fs.exists(cachePath)) {
      try {
        final cached = await context.fs.readString(cachePath);
        final trim = cached.trim();
        if (trim.isNotEmpty && await context.fs.exists(trim)) {
          _selectedTarget = trim;
        }
      } catch (_) {}
    }
  }

  Future<void> _saveCache() async {
    if (_selectedTarget == null) return;
    final cachePath = await _getCachePath();
    if (cachePath != null) {
      try {
        final dir = io.Directory(path.dirname(cachePath));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        await context.fs.writeString(cachePath, _selectedTarget!);
      } catch (_) {}
    }
  }

  Future<void> init() async {
    _isLoading = true;
    await _updateToolbar();

    try {
      await _loadCache();

      if (_selectedTarget == null) {
        final root = await projectService.getProjectRoot();
        final defaultTarget = path.join(root, 'lib', 'main.dart');
        if (await context.fs.exists(defaultTarget)) {
          _selectedTarget = defaultTarget;
        }
      }
    } catch (_) {
      // Ignore if no project root is found initially
    }

    _isLoading = false;
    await _updateToolbar();
  }

  /// Walks up from [filePath] towards [root] looking for the nearest
  /// `pubspec.yaml` and returns that directory's basename as the package name.
  Future<String> _findPackageName(String filePath, String root) async {
    var curr = path.dirname(filePath);
    while (curr != root && curr.length >= root.length) {
      final pubspecPath = path.join(curr, 'pubspec.yaml');
      if (await context.fs.exists(pubspecPath)) {
        return path.basename(curr);
      }
      curr = path.dirname(curr);
    }
    return path.basename(root);
  }

  Future<void> selectTarget(
      [Map<String, int>? position, bool forceRefresh = false]) async {
    // Loop instead of recursion so "Refresh" doesn't grow the stack.
    var refresh = forceRefresh;
    while (true) {
      final items = <QuickPickItem>[];
      String? root;

      try {
        root = await projectService.getProjectRoot();
      } catch (_) {}

      if (root != null) {
        final mainDartFiles =
            await projectService.findAllTargets(forceRefresh: refresh);

        for (final absolutePath in mainDartFiles) {
          final rel = path.relative(absolutePath, from: root);
          final packageName = await _findPackageName(absolutePath, root);

          items.add(QuickPickItem(
            label: path.basename(absolutePath),
            description: packageName,
            tooltip: rel,
            payload: absolutePath,
            icon: iconCode,
          ));
        }

        if (_selectedTarget != null &&
            !items.any((i) => i.payload == _selectedTarget)) {
          final rel = path.relative(_selectedTarget!, from: root);
          final packageName = await _findPackageName(_selectedTarget!, root);

          items.add(QuickPickItem(
            label: path.basename(_selectedTarget!),
            description: packageName,
            tooltip: rel,
            payload: _selectedTarget,
            icon: iconCode,
          ));
        }
      }

      items.add(const QuickPickItem(label: '', isSeparator: true));
      items.add(const QuickPickItem(
        label: 'Enter custom target path...',
        detail: 'Provide a relative path to your Dart entry point',
        payload: 'custom',
        icon: iconEdit,
      ));
      items.add(const QuickPickItem(
        label: 'Refresh Targets...',
        detail: 'Scan for new dart targets natively',
        payload: 'refresh',
        icon: iconRefresh,
      ));

      final selected = await context.window.showQuickPick(
        items,
        placeholder: 'Select run target entry point',
        position: position,
      );

      if (selected != null) {
        final payload = selected.payload as String;
        if (payload == 'refresh') {
          await context.window.showMessage('Scanning for flutter targets');
          refresh = true;
          continue; // Re-open picker via loop iteration
        } else if (payload == 'custom') {
          final customPath = await context.window.showInputBox(
            prompt:
                'Enter relative path to Dart entry point (e.g. lib/main.dart)',
          );
          if (customPath != null && customPath.isNotEmpty) {
            if (root != null) {
              String fullPath = path.isAbsolute(customPath)
                  ? customPath
                  : path.join(root, customPath);
              if (await context.fs.exists(fullPath)) {
                _selectedTarget = fullPath;
              } else {
                await context.window.showMessage(
                  'File not found: $fullPath',
                  type: MessageType.error,
                );
                return;
              }
            } else {
              // Cannot validate file if no workspace root.
              _selectedTarget = customPath;
            }
          }
        } else {
          _selectedTarget = payload;
        }
        await _saveCache();
        await _updateToolbar();
      }
      return;
    }
  }

  Future<void> _updateToolbar() async {
    if (_isLoading) {
      await context.toolbar.registerItem(
        id: cmdFlutterTarget,
        icon: '',
        label: 'Detecting...',
        tooltip: 'Detecting run targets...',
        alignment: ToolbarItemAlignment.right,
        priority: 190, // Next to device picker (200)
      );
      return;
    }

    String label = 'Select Target';
    String tooltip = 'Select Target Entry Point';

    if (_selectedTarget != null) {
      label = path.basename(_selectedTarget!);

      String? root;
      try {
        root = await projectService.getProjectRoot();
      } catch (_) {}

      if (root != null && path.isWithin(root, _selectedTarget!)) {
        tooltip = path.relative(_selectedTarget!, from: root);
      } else {
        tooltip = 'Entry Point: $_selectedTarget';
      }
    }

    await context.toolbar.registerItem(
      id: cmdFlutterTarget,
      icon: '',
      label: label,
      tooltip: tooltip,
      alignment: ToolbarItemAlignment.right,
      priority: 190,
    );
  }

  String? get selectedTarget => _selectedTarget;

  Future<void> dispose() async {
    await context.toolbar.unregisterItem(cmdFlutterTarget);
  }
}
