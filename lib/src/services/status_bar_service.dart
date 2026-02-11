import 'dart:io';

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

    String iconPath = p.normalize(
      p.join(scriptDir, '..', folderAssets, assetIconFlutterSolid),
    );

    if (!await File(iconPath).exists()) {
      iconPath = p.normalize(
        p.join(scriptDir, folderAssets, assetIconFlutterSolid),
      );
    }

    await context.statusBar.createItem(
      id: _versionItemId,
      text: '',
      alignment: 'right',
      priority: 100,
      tooltip: 'Flutter Tools',
      command: cmdFlutterTools,
      iconPath: await File(iconPath).exists() ? iconPath : null,
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
