import 'dart:convert';
import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:path/path.dart' as path;

/// A single `"launch"` configuration entry parsed from `.vscode/launch.json`.
///
/// Only entries with `"type": "dart"` and `"request": "launch"` are included.
final class VscodeLaunchEntry {
  const VscodeLaunchEntry({
    required this.name,
    required this.program,
    required this.isFlutter,
    this.cwd,
    this.flutterMode,
    this.flavorName,
    this.deviceId,
    this.toolArgs = const [],
    this.args = const [],
    this.env = const {},
  });

  /// The `"name"` field — shown as the label in the target picker.
  final String name;

  /// Resolved absolute path to the Dart entry point (from `"program"`).
  final String program;

  /// Whether this is a Flutter launch (vs plain Dart).
  ///
  /// Determined by: `"flutterMode"` or `"deviceId"` being present in the
  /// config, or by the nearest `pubspec.yaml` referencing the Flutter SDK.
  final bool isFlutter;

  /// `"cwd"` — working directory override.
  final String? cwd;

  /// `"flutterMode"` — `"debug"`, `"profile"`, or `"release"`.
  final String? flutterMode;

  /// `"flavorName"` — passed as `--flavor` to `flutter run`.
  final String? flavorName;

  /// `"deviceId"` — device override from the config (informational; Lumide
  /// uses its own device picker and will ignore this unless the user
  /// explicitly has no device selected).
  final String? deviceId;

  /// `"toolArgs"` — arguments inserted between `flutter run` and `-t target`.
  ///
  /// Example: `["--dart-define", "MY_VAR=foo", "--enable-experiment=patterns"]`
  final List<String> toolArgs;

  /// `"args"` — arguments passed to `main()` (after the target script).
  final List<String> args;

  /// `"env"` — environment variables to set when launching.
  final Map<String, String> env;

  /// Asset icon path, based on whether this is a Flutter or Dart launch.
  String get iconPath => switch (isFlutter) {
        true => assetIconFlutter,
        false => assetIconDart,
      };
}

/// Contextual data needed to resolve dynamic VS Code variables.
final class DynamicVariableContext {
  const DynamicVariableContext({
    required this.workspaceRoot,
    this.filePath,
    this.lineNumber,
    this.columnNumber,
    this.selectedText,
  });

  final String? workspaceRoot;
  final String? filePath;
  final int? lineNumber;
  final int? columnNumber;
  final String? selectedText;
}

class LaunchConfigService {
  LaunchConfigService(this.context, this.projectService, this._log);

  final LumideContext context;
  final ProjectService projectService;
  final void Function(String) _log;

  List<VscodeLaunchEntry> _entries = const [];

  /// The parsed launch configurations. Empty if no `.vscode/launch.json`
  /// exists or if the file is malformed.
  List<VscodeLaunchEntry> get entries => _entries;

  Future<void> Function()? onDidChange;

  /// Fetches the current editor state to resolve dynamic variables.
  Future<DynamicVariableContext> fetchVariableContext() async {
    final workspaceRoot = await context.workspace.getRootUri();
    final uri = await context.editor.getActiveDocumentUri();
    final filePath = switch (uri) {
      final String u => Uri.parse(u).toFilePath(),
      _ => null,
    };

    int? line;
    int? col;
    final selections = await context.editor.getSelections();
    if (selections.isNotEmpty) {
      final focus = selections.first['focus'] as Map<String, dynamic>?;
      line = focus?['line'] as int?;
      col = focus?['column'] as int?;
    }

    final selectedText = await context.editor.getSelectedText();

    return DynamicVariableContext(
      workspaceRoot: workspaceRoot,
      filePath: filePath,
      lineNumber: line,
      columnNumber: col,
      selectedText: selectedText,
    );
  }

  Future<void> init() async {
    await reload();

    context.workspace.onDidSaveTextDocument((uri) async {
      if (!uri.endsWith('launch.json')) return;
      await reload();
      await _notifyChanged();
    });
  }

  Future<void> reload() async {
    final jsonPath = await _launchJsonPath();
    if (jsonPath == null) {
      _log(
          '[LaunchConfig] workspace root URI is null — cannot locate launch.json');
      _entries = const [];
      return;
    }

    _log('[LaunchConfig] looking for launch.json at: $jsonPath');

    final file = io.File(jsonPath);
    if (!await file.exists()) {
      _log(
          '[LaunchConfig] launch.json not found — no VS Code configurations loaded');
      _entries = const [];
      return;
    }

    final workspaceRoot = await context.workspace.getRootUri();

    String? projectRoot;
    try {
      projectRoot = await projectService.getProjectRoot();
    } catch (_) {}
    final root = projectRoot ?? workspaceRoot;

    try {
      final raw = await file.readAsString();
      final stripped = _stripComments(raw);
      final decoded = jsonDecode(stripped);

      if (decoded is! Map<String, dynamic>) {
        _entries = const [];
        return;
      }

      final configurations =
          decoded['configurations'] ?? decoded['configuration'];
      if (configurations is! List) {
        _entries = const [];
        return;
      }

      final entries = <VscodeLaunchEntry>[];
      final seenNames = <String>{};
      for (final config in configurations) {
        try {
          if (config is! Map<String, dynamic>) continue;

          if (config['type'] != 'dart') continue;

          if (config['request'] != 'launch') continue;

          final rawName = config['name'] as String?;
          if (rawName == null || rawName.isEmpty) continue;

          var name = rawName;
          var suffix = 2;
          while (seenNames.contains(name)) {
            name = '$rawName ($suffix)';
            suffix++;
          }
          seenNames.add(name);

          final program = config['program'] as String? ?? 'lib/main.dart';
          if (program.isEmpty) continue;

          final resolvedProgram =
              _resolvePath(program, workspaceRoot, skipDynamic: true);
          if (resolvedProgram == null) continue;

          final flutterMode = config['flutterMode'] as String?;
          final flavorName = config['flavorName'] as String?;
          final deviceId = config['deviceId'] as String?;

          final resolvedCwd = switch (config['cwd'] as String?) {
            final String cwd when cwd.isNotEmpty =>
              _resolvePath(cwd, workspaceRoot, skipDynamic: true) ?? cwd,
            _ => null,
          };

          final toolArgs = _stringList(config['toolArgs'])
              .map((a) => _expandVars(a, workspaceRoot, skipDynamic: true))
              .toList();
          final args = _stringList(config['args'])
              .map((a) => _expandVars(a, workspaceRoot, skipDynamic: true))
              .toList();
          final env = _stringMap(config['env']).map(
            (k, v) =>
                MapEntry(k, _expandVars(v, workspaceRoot, skipDynamic: true)),
          );

          String? resolvedDeviceId = deviceId;
          if (resolvedDeviceId == null) {
            for (int i = 0; i < toolArgs.length - 1; i++) {
              if (toolArgs[i] == '-d' || toolArgs[i] == '--device-id') {
                resolvedDeviceId = toolArgs[i + 1];
                toolArgs.removeAt(i + 1);
                toolArgs.removeAt(i);
                break;
              }
            }
          }
          if (resolvedDeviceId == null) {
            for (int i = 0; i < args.length - 1; i++) {
              if (args[i] == '-d' || args[i] == '--device-id') {
                resolvedDeviceId = args[i + 1];
                args.removeAt(i + 1);
                args.removeAt(i);
                break;
              }
            }
          }

          final hasFlutterFields =
              flutterMode != null || resolvedDeviceId != null;
          final isFlutter = hasFlutterFields ||
              await _isFlutterProject(resolvedProgram, root);

          entries.add(VscodeLaunchEntry(
            name: name,
            program: resolvedProgram,
            isFlutter: isFlutter,
            cwd: resolvedCwd,
            flutterMode: flutterMode,
            flavorName: flavorName,
            deviceId: resolvedDeviceId,
            toolArgs: toolArgs,
            args: args,
            env: env,
          ));
        } catch (_) {
          continue;
        }
      }

      _entries = entries;
      _log(
          '[LaunchConfig] loaded ${entries.length} VS Code launch configuration(s)');
    } catch (e, st) {
      _log('[LaunchConfig] failed to parse launch.json: $e\n$st');
      _entries = const [];
    }
  }

  /// Checks whether [filePath]'s nearest `pubspec.yaml` references Flutter.
  Future<bool> _isFlutterProject(String filePath, String? root) async {
    var curr = path.dirname(filePath);
    final boundary = path.normalize(root ?? path.rootPrefix(filePath));
    while (curr.length >= boundary.length) {
      final pubspecPath = path.join(curr, 'pubspec.yaml');
      final file = io.File(pubspecPath);
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          return content.contains('sdk: flutter') ||
              content.contains('flutter:');
        } catch (_) {
          return false;
        }
      }
      final parent = path.dirname(curr);
      if (parent == curr) break;
      curr = parent;
    }
    return false;
  }

  Future<String?> _launchJsonPath() async {
    final workspaceRoot = await context.workspace.getRootUri();
    if (workspaceRoot == null) return null;
    return path.join(workspaceRoot, '.vscode', 'launch.json');
  }

  static final _commentRegex =
      RegExp(r'("(?:\\.|[^"\\])*")|//.*|/\*[\s\S]*?\*/');

  static final _variableRegex = RegExp(r'\${([^}]+)}');

  static final _dynamicVariableRegex = RegExp(
    r'\${(file|fileBasename|fileBasenameNoExtension|fileExtname|fileDirname|fileDirnameBasename|relativeFile|relativeFileDirname|lineNumber|columnNumber|selectedText|fileWorkspaceFolder)}',
  );

  /// Returns true if the given [entry] or any of the [additional] strings
  /// contain VS Code variables that depend on the active editor state.
  bool needsDynamicResolution(VscodeLaunchEntry? entry,
      [Iterable<String?> additional = const []]) {
    if (entry != null) {
      if (_dynamicVariableRegex.hasMatch(entry.program)) return true;
      if (entry.cwd case final cwd? when _dynamicVariableRegex.hasMatch(cwd)) {
        return true;
      }
      if (entry.flutterMode case final mode?
          when _dynamicVariableRegex.hasMatch(mode)) {
        return true;
      }
      if (entry.flavorName case final flavor?
          when _dynamicVariableRegex.hasMatch(flavor)) {
        return true;
      }
      if (entry.deviceId case final device?
          when _dynamicVariableRegex.hasMatch(device)) {
        return true;
      }
      if (entry.toolArgs.any(_dynamicVariableRegex.hasMatch)) return true;
      if (entry.args.any(_dynamicVariableRegex.hasMatch)) return true;
      if (entry.env.values.any(_dynamicVariableRegex.hasMatch)) return true;
    }
    for (final s in additional) {
      if (s case final val? when _dynamicVariableRegex.hasMatch(val)) {
        return true;
      }
    }
    return false;
  }

  /// Strips single-line `//` and multi-line `/* */` comments.
  String _stripComments(String source) {
    return source.replaceAllMapped(
      _commentRegex,
      (match) {
        final stringLiteral = match.group(1);
        return stringLiteral ?? '';
      },
    );
  }

  /// Expands VS Code variables (e.g. `${workspaceFolder}`, `${env:NAME}`) in [value].
  String _expandVars(String value, String? root, {bool skipDynamic = false}) {
    if (!value.contains(r'$')) return value;

    return value.replaceAllMapped(_variableRegex, (match) {
      final varName = match.group(1)!;

      if (skipDynamic) {
        const dynamicVars = {
          'file',
          'fileBasename',
          'fileBasenameNoExtension',
          'fileExtname',
          'fileDirname',
          'fileDirnameBasename',
          'relativeFile',
          'relativeFileDirname',
          'lineNumber',
          'columnNumber',
          'selectedText',
          'fileWorkspaceFolder',
        };
        if (dynamicVars.contains(varName)) return match.group(0)!;
      }

      if (varName == 'workspaceFolder' || varName == 'workspaceRoot') {
        return root ?? match.group(0)!;
      }
      if (varName == 'workspaceFolderBasename') {
        return switch (root) {
          final String r => path.basename(r),
          _ => match.group(0)!,
        };
      }

      if (varName == 'userHome') {
        return switch (io.Platform.isWindows) {
          true => io.Platform.environment['USERPROFILE'] ?? '',
          false => io.Platform.environment['HOME'] ?? '',
        };
      }
      if (varName == 'pathSeparator' || varName == '/') {
        return path.separator;
      }
      if (varName == 'cwd') {
        return io.Directory.current.path;
      }

      if (varName.startsWith('env:')) {
        final envName = varName.substring(4);
        return io.Platform.environment[envName] ?? '';
      }

      return match.group(0)!;
    });
  }

  /// Resolves dynamic VS Code variables that depend on the active editor state.
  Future<String> resolveDynamicVariables(
    String value, {
    DynamicVariableContext? ctx,
  }) async {
    if (!value.contains(r'$')) return value;

    if (ctx == null && !_dynamicVariableRegex.hasMatch(value)) {
      return value;
    }

    final contextData = ctx ?? await fetchVariableContext();
    final workspaceRoot = contextData.workspaceRoot;
    final filePath = contextData.filePath;

    return value.replaceAllMapped(_variableRegex, (match) {
      final varName = match.group(1)!;

      if (filePath != null) {
        if (varName == 'file') return filePath;
        if (varName == 'fileBasename') return path.basename(filePath);
        if (varName == 'fileBasenameNoExtension') {
          return path.basenameWithoutExtension(filePath);
        }
        if (varName == 'fileExtname') return path.extension(filePath);
        if (varName == 'fileDirname') return path.dirname(filePath);
        if (varName == 'fileDirnameBasename') {
          return path.basename(path.dirname(filePath));
        }
        if (varName == 'fileWorkspaceFolder') return workspaceRoot ?? '';

        if (workspaceRoot != null && path.isWithin(workspaceRoot, filePath)) {
          final relative = path.relative(filePath, from: workspaceRoot);
          if (varName == 'relativeFile') {
            return relative;
          }
          if (varName == 'relativeFileDirname') {
            return path.dirname(relative);
          }
        }
      }

      if (varName == 'lineNumber') {
        return switch (contextData.lineNumber) {
          final int l => l.toString(),
          _ => match.group(0)!,
        };
      }
      if (varName == 'columnNumber') {
        return switch (contextData.columnNumber) {
          final int c => c.toString(),
          _ => match.group(0)!,
        };
      }
      if (varName == 'selectedText') {
        return contextData.selectedText ?? match.group(0)!;
      }

      return match.group(0)!;
    });
  }

  Future<String> resolveAllVariables(String value) async {
    if (!value.contains(r'$')) return value;

    if (!_dynamicVariableRegex.hasMatch(value)) {
      final root = await context.workspace.getRootUri();
      return _expandVars(value, root);
    }

    final ctx = await fetchVariableContext();
    final resolved = _expandVars(value, ctx.workspaceRoot);
    return resolveDynamicVariables(resolved, ctx: ctx);
  }

  String? _resolvePath(String p, String? root, {bool skipDynamic = false}) {
    final resolved = _expandVars(p, root, skipDynamic: skipDynamic);

    if (skipDynamic && resolved.startsWith(r'${')) {
      return resolved;
    }

    if (!path.isAbsolute(resolved)) {
      if (root == null) return null;
      return path.join(root, resolved);
    }
    return resolved;
  }

  List<String> _stringList(dynamic value) => switch (value) {
        final List list =>
          list.whereType<String>().where((s) => s.isNotEmpty).toList(),
        _ => <String>[],
      };

  Map<String, String> _stringMap(dynamic value) {
    if (value is! Map<String, dynamic>) return const {};
    return {
      for (final e in value.entries) e.key: e.value.toString(),
    };
  }

  Future<void> _notifyChanged() async {
    final callback = onDidChange;
    if (callback != null) {
      await callback();
    }
  }

  Future<void> dispose() async {}
}
