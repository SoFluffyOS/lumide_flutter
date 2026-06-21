import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/launch_config_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:path/path.dart' as path;

class TargetService {
  final LumideContext context;
  final ProjectService projectService;
  final LaunchConfigService launchConfigService;

  String? _selectedTarget;
  VscodeLaunchEntry? _selectedVscodeEntry;
  bool _isLoading = true;
  Future<void> Function()? onDidChange;

  TargetService(this.context, this.projectService, this.launchConfigService);

  VscodeLaunchEntry? get selectedVscodeEntry => _selectedVscodeEntry;

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
    if (cachePath == null || !io.File(cachePath).existsSync()) return;
    try {
      final cached = (await io.File(cachePath).readAsString()).trim();
      if (cached.isEmpty) return;

      if (cached.startsWith(vscodeConfigPrefix)) {
        // Restore a previously selected VS Code launch entry.
        final name = cached.substring(vscodeConfigPrefix.length);
        final entry = launchConfigService.entries
            .where((e) => e.name == name)
            .firstOrNull;
        if (entry != null) {
          _selectedVscodeEntry = entry;
          _selectedTarget = null;
        }
        return;
      }

      if (io.File(cached).existsSync()) {
        _selectedTarget = cached;
        _selectedVscodeEntry = null;
      }
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    final cacheValue = switch (_selectedVscodeEntry) {
      final VscodeLaunchEntry entry => '$vscodeConfigPrefix${entry.name}',
      _ => _selectedTarget,
    };
    if (cacheValue == null) return;
    final cachePath = await _getCachePath();
    if (cachePath == null) return;
    try {
      final dir = io.Directory(path.dirname(cachePath));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      await io.File(cachePath).writeAsString(cacheValue);
    } catch (_) {}
  }

  Future<void> init() async {
    _isLoading = true;
    await _notifyChanged();

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
    await _notifyChanged();
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
    var refresh = forceRefresh;
    while (true) {
      final items = <QuickPickItem>[];
      String? root;

      try {
        root = await projectService.getProjectRoot();
      } catch (_) {}

      final vscodeEntries = launchConfigService.entries;
      if (vscodeEntries.isNotEmpty) {
        items.add(const QuickPickItem(
          label: 'VS Code Configurations',
          isSeparator: true,
        ));
        for (final entry in vscodeEntries) {
          items.add(QuickPickItem(
            label: entry.name,
            description: path.basename(entry.program),
            tooltip: entry.program,
            payload: '$vscodeConfigPrefix${entry.name}',
            iconPath: entry.iconPath,
            noTint: true,
          ));
        }
      }

      if (root != null) {
        final mainDartFiles =
            await projectService.findAllTargets(forceRefresh: refresh);

        if (mainDartFiles.isNotEmpty) {
          if (vscodeEntries.isNotEmpty) {
            items.add(const QuickPickItem(
              label: 'Dart Entry Points',
              isSeparator: true,
            ));
          }

          for (final absolutePath in mainDartFiles) {
            final rel = path.relative(absolutePath, from: root);
            final packageName = await _findPackageName(absolutePath, root);
            final targetIcon = await getTargetIcon(absolutePath);

            items.add(QuickPickItem(
              label: path.basename(absolutePath),
              description: packageName,
              tooltip: rel,
              payload: absolutePath,
              icon: targetIcon.icon,
              iconPath: targetIcon.iconPath,
              noTint: targetIcon.noTint,
            ));
          }
        }

        if (_selectedTarget != null &&
            !items.any((i) => i.payload == _selectedTarget)) {
          final rel = path.relative(_selectedTarget!, from: root);
          final packageName = await _findPackageName(_selectedTarget!, root);
          final targetIcon = await getTargetIcon(_selectedTarget!);

          items.add(QuickPickItem(
            label: path.basename(_selectedTarget!),
            description: packageName,
            tooltip: rel,
            payload: _selectedTarget,
            icon: targetIcon.icon,
            iconPath: targetIcon.iconPath,
            noTint: targetIcon.noTint,
          ));
        }
      }

      if (items.isNotEmpty) {
        items.add(const QuickPickItem(label: '', isSeparator: true));
      }
      items.add(const QuickPickItem(
        label: 'Enter custom target path...',
        description: 'Custom path',
        detail: 'Relative Dart entry point path',
        tooltip:
            'Enter a relative path to a Dart entry point, for example lib/main.dart.',
        payload: 'custom',
        icon: iconEdit,
      ));
      items.add(const QuickPickItem(
        label: 'Refresh Targets...',
        description: 'Rescan',
        detail: 'Scan for Dart entry points',
        tooltip: 'Scan the workspace for newly added Dart entry point files.',
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
          await launchConfigService.reload();
          refresh = true;
          continue;
        } else if (payload == 'custom') {
          final selectedTarget = await setCustomTarget();
          if (selectedTarget == null) {
            return;
          }
        } else if (payload.startsWith(vscodeConfigPrefix)) {
          final name = payload.substring(vscodeConfigPrefix.length);
          final entry = launchConfigService.entries
              .where((e) => e.name == name)
              .firstOrNull;
          if (entry != null) {
            await setSelectedVscodeEntry(entry);
          }
        } else {
          await setSelectedTarget(payload);
          return;
        }
        await _saveCache();
        await _notifyChanged();
      }
      return;
    }
  }

  Future<List<String>> launchTargets({bool forceRefresh = false}) async {
    String? root;
    try {
      root = await projectService.getProjectRoot();
    } catch (_) {}

    final targets = <String>[];
    if (root != null) {
      targets.addAll(
        await projectService.findAllTargets(forceRefresh: forceRefresh),
      );
    }

    final selected = _selectedTarget;
    if (selected != null && !targets.contains(selected)) {
      targets.add(selected);
    }

    return targets;
  }

  Future<void> setSelectedTarget(String target) async {
    _selectedTarget = target;
    _selectedVscodeEntry = null;
    await _saveCache();
    await _notifyChanged();
  }

  Future<void> setTargetFromContext(Map<String, dynamic>? args) async {
    final candidate = projectService.pathFromMenuContext(args);
    if (candidate == null || path.extension(candidate) != '.dart') {
      await context.window.showMessage(
        'Select a Dart file to use as a Flutter target.',
        type: MessageType.warning,
      );
      return;
    }

    if (!await context.fs.exists(candidate)) {
      await context.window.showMessage(
        'Target file not found: $candidate',
        type: MessageType.error,
      );
      return;
    }

    await setSelectedTarget(candidate);
    await refreshTargets();
    await context.window.showMessage(
      'Flutter target set to ${path.basename(candidate)}.',
    );
  }

  Future<void> setSelectedVscodeEntry(VscodeLaunchEntry entry) async {
    _selectedVscodeEntry = entry;
    _selectedTarget = null;
    await _saveCache();
    await _notifyChanged();
  }

  Future<String> displayLabelFor(String target) async {
    return path.basename(target);
  }

  Future<String> displayTooltipFor(String target) async {
    String? root;
    try {
      root = await projectService.getProjectRoot();
    } catch (_) {}

    if (root != null && path.isWithin(root, target)) {
      return path.relative(target, from: root);
    }

    return 'Entry Point: $target';
  }

  Future<String> packageNameFor(String target) async {
    try {
      final root = await projectService.getProjectRoot();
      return await _findPackageName(target, root);
    } catch (_) {
      return path.basename(path.dirname(target));
    }
  }

  Future<String?> setCustomTarget([String? customPath]) async {
    final input = customPath ??
        await context.window.showOpenDialog(
          title: 'Select Flutter Target',
        );
    if (input == null) return null;

    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    String? root;
    try {
      root = await projectService.getProjectRoot();
    } catch (_) {}

    if (root != null) {
      final fullPath =
          path.isAbsolute(trimmed) ? trimmed : path.join(root, trimmed);
      if (io.File(fullPath).existsSync()) {
        _selectedTarget = fullPath;
        await _saveCache();
        await _notifyChanged();
        return fullPath;
      }

      await context.window.showMessage(
        'File not found: $fullPath',
        type: MessageType.error,
      );
      return null;
    }

    _selectedTarget = trimmed;
    await _saveCache();
    await _notifyChanged();
    return trimmed;
  }

  Future<void> refreshTargets([Map<String, int>? position]) async {
    _isLoading = true;
    await _notifyChanged();

    try {
      await projectService.getProjectRoot();
      await Future.wait([
        projectService.findAllTargets(forceRefresh: true),
        launchConfigService.reload(),
      ]);
    } catch (_) {}

    _isLoading = false;
    await _notifyChanged();
  }

  Future<void> _notifyChanged() async {
    final callback = onDidChange;
    if (callback != null) {
      await callback();
    }
  }

  Future<String> displayLabel() async {
    if (_isLoading) return 'Detecting...';

    if (_selectedVscodeEntry != null) {
      return _selectedVscodeEntry!.name;
    }

    if (_selectedTarget != null) {
      return path.basename(_selectedTarget!);
    }

    return 'Select Target';
  }

  Future<String> displayTooltip() async {
    if (_isLoading) return 'Detecting run targets...';

    if (_selectedVscodeEntry != null) {
      final entry = _selectedVscodeEntry!;
      return '${entry.name} (${path.basename(entry.program)})';
    }

    if (_selectedTarget == null) return 'Select Target Entry Point';

    String? root;
    try {
      root = await projectService.getProjectRoot();
    } catch (_) {}

    if (root != null && path.isWithin(root, _selectedTarget!)) {
      return path.relative(_selectedTarget!, from: root);
    }

    return 'Entry Point: $_selectedTarget';
  }

  String? get selectedTarget => _selectedTarget;

  Future<({String? icon, String? iconPath, bool noTint})> getTargetIcon(
      String targetPath) async {
    final pubspecPath = await _findPubspecPath(targetPath);
    if (pubspecPath == null) {
      return (icon: null, iconPath: null, noTint: false);
    }
    try {
      final content = await io.File(pubspecPath).readAsString();
      final isFlutter =
          content.contains('sdk: flutter') || content.contains('flutter:');
      if (isFlutter) {
        return (icon: null, iconPath: assetIconFlutter, noTint: true);
      }
    } catch (_) {}
    return (icon: null, iconPath: assetIconDart, noTint: true);
  }

  Future<String?> _findPubspecPath(String filePath) async {
    try {
      final root = await projectService.getProjectRoot();
      var curr = path.dirname(filePath);
      while (curr.length >= root.length) {
        final pubspecPath = path.join(curr, 'pubspec.yaml');
        if (io.File(pubspecPath).existsSync()) {
          return pubspecPath;
        }
        final parent = path.dirname(curr);
        if (parent == curr) break;
        curr = parent;
      }
      final rootPubspec = path.join(root, 'pubspec.yaml');
      if (io.File(rootPubspec).existsSync()) {
        return rootPubspec;
      }
    } catch (_) {}
    return null;
  }

  Future<void> dispose() async {
    await context.toolbar.unregisterItem(cmdFlutterTarget);
  }
}
