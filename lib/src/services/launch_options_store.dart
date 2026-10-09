import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// Persists per-project launch selections (target, flavor, build mode, tool
/// args) in the plugin's private storage, so `flutter clean` does not reset
/// them.
///
/// Values written by older versions under `<project>/.dart_tool/lumide/` are
/// read once as a fallback. When no storage directory is available the legacy
/// location stays in use.
class LaunchOptionsStore {
  LaunchOptionsStore({
    required Future<String?> Function() storageDir,
    required Future<String> Function() projectRoot,
  })  : _storageDir = storageDir,
        _projectRoot = projectRoot;

  static const String flavorKey = 'flavor';
  static const String buildModeKey = 'build_mode';
  static const String toolArgsKey = 'tool_args';
  static const String targetKey = 'target';

  final Future<String?> Function() _storageDir;
  final Future<String> Function() _projectRoot;
  final Map<String, Future<Map<String, String>>> _valuesByFile = {};
  Future<void> _writes = Future.value();

  Future<String?> read(String key) async {
    final location = await _location();
    if (location == null) return null;

    final storeFile = location.storeFile;
    if (storeFile != null) {
      final values = await _load(storeFile);
      if (values.containsKey(key)) return values[key];
    }
    return _readLegacy(location.projectRoot, key);
  }

  Future<void> write(String key, String value) async {
    final location = await _location();
    if (location == null) return;

    final storeFile = location.storeFile;
    if (storeFile == null) {
      await _writeLegacy(location.projectRoot, key, value);
      return;
    }

    final values = await _load(storeFile);
    values[key] = value;
    final snapshot = jsonEncode(values);
    final write = _writes.then((_) => _writeFile(storeFile, snapshot));
    _writes = write.catchError((Object _) {});
    await write;
  }

  Future<({String projectRoot, String? storeFile})?> _location() async {
    final String projectRoot;
    try {
      projectRoot = path.normalize(await _projectRoot());
    } catch (_) {
      return null;
    }

    final String? storageDir;
    try {
      storageDir = await _storageDir();
    } catch (_) {
      return (projectRoot: projectRoot, storeFile: null);
    }
    if (storageDir == null || storageDir.isEmpty) {
      return (projectRoot: projectRoot, storeFile: null);
    }

    final fileName = '${path.basename(projectRoot)}-'
        '${_stableHash(projectRoot)}.json';
    return (
      projectRoot: projectRoot,
      storeFile: path.join(storageDir, 'launch_options', fileName),
    );
  }

  Future<Map<String, String>> _load(String storeFile) {
    return _valuesByFile[storeFile] ??= _readStore(storeFile);
  }

  Future<Map<String, String>> _readStore(String storeFile) async {
    final values = <String, String>{};
    try {
      final file = File(storeFile);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final MapEntry(:key, :value) in decoded.entries) {
            if (key is String && value is String) values[key] = value;
          }
        }
      }
    } catch (_) {}
    return values;
  }

  Future<void> _writeFile(String filePath, String contents) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  String _legacyPath(String projectRoot, String key) =>
      path.join(projectRoot, '.dart_tool', 'lumide', '$key.txt');

  Future<String?> _readLegacy(String projectRoot, String key) async {
    try {
      final file = File(_legacyPath(projectRoot, key));
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLegacy(String projectRoot, String key, String value) async {
    try {
      await _writeFile(_legacyPath(projectRoot, key), value);
    } catch (_) {}
  }

  /// FNV-1a, so the file name stays the same across plugin restarts.
  static String _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
