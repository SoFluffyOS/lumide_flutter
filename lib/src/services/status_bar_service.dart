import 'dart:io';
import 'dart:isolate';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:path/path.dart' as p;

class StatusBarService {
  final LumideContext context;

  static const String _versionItemId = 'flutter.version';

  StatusBarService(this.context);

  Future<void> init() async {
    final scriptPath = Platform.script.toFilePath();
    final scriptDir = p.dirname(scriptPath);

    final paths = [
      p.join(scriptDir, '..', folderAssets, assetIconFlutterSolid),
      p.join(scriptDir, folderAssets, assetIconFlutterSolid),
      p.join(Directory.current.path, folderAssets, assetIconFlutterSolid),
    ];

    String? foundPath;

    try {
      final baseUri = Uri.parse('package:lumide_flutter/lumide_flutter.dart');
      final resolvedBase = await Isolate.resolvePackageUri(baseUri);

      if (resolvedBase != null && resolvedBase.isScheme('file')) {
        final libDir = p.dirname(resolvedBase.toFilePath());
        final packageRoot = p.dirname(libDir);
        final assetPath = p.normalize(
          p.join(packageRoot, folderAssets, assetIconFlutterSolid),
        );

        if (await File(assetPath).exists()) {
          foundPath = assetPath;
        }
      }
    } catch (_) {}

    if (foundPath == null) {
      for (final path in paths) {
        final normalized = p.normalize(path);
        if (await File(normalized).exists()) {
          foundPath = normalized;
          break;
        }
      }
    }

    await context.statusBar.createItem(
      id: _versionItemId,
      text: '',
      alignment: 'right',
      priority: 100,
      tooltip: 'Flutter Tools',
      command: cmdFlutterTools,
      iconPath: foundPath,
    );
  }

  Future<void> updateVersion(String version) async {
    await context.statusBar.updateItem(
      _versionItemId,
      text: '',
      tooltip: 'Flutter $version',
      command: cmdFlutterTools,
    );
  }

  Future<void> dispose() async {
    await context.statusBar.disposeItem(_versionItemId);
  }
}
