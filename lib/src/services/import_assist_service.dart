import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/import_assist.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:path/path.dart' as path;

/// Syncs Flutter-related imports after snippet use / on save (add + remove unused).
class ImportAssistService {
  ImportAssistService(
    this.context,
    this.projectService,
    this.logService,
  );

  final LumideContext context;
  final ProjectService projectService;
  final LogService logService;

  Future<void> init() async {
    context.workspace.onDidSaveTextDocument((uri) {
      unawaited(syncImportsForUri(uri, quiet: true));
    });
  }

  Future<void> ensureImportsForActiveDocument() async {
    final uri = await context.editor.getActiveDocumentUri();
    if (uri == null || uri.isEmpty) {
      await context.window.showMessage(
        'No active document.',
        type: MessageType.warning,
      );
      return;
    }
    final result = await syncImportsForUri(uri, quiet: false);
    if (result == null) return;
    if (result.isNoOp) {
      await context.window.showMessage('Flutter imports already up to date.');
      return;
    }

    final parts = <String>[];
    if (result.added.isNotEmpty) {
      parts.add('added ${result.added.length}');
    }
    if (result.removed.isNotEmpty) {
      parts.add('removed ${result.removed.length}');
    }
    await context.window.showMessage(
      'Flutter imports ${parts.join(', ')}.',
    );
  }

  /// Returns sync result, or null if the file was skipped.
  Future<ImportSyncResult?> syncImportsForUri(
    String uri, {
    required bool quiet,
  }) async {
    final filePath = _pathFromUri(uri);
    if (filePath == null || !filePath.endsWith('.dart')) {
      return null;
    }

    try {
      final projectRoot = await projectService.findProjectRootForPath(filePath);
      if (projectRoot == null ||
          !await projectService.isFlutterProject(projectRoot)) {
        return null;
      }

      var removeUnused = true;
      if (quiet) {
        final autoEnabled = await context.workspace
                .getConfiguration(confAutoImportOnSave) as bool? ??
            defaultAutoImportOnSave;
        if (!autoEnabled) return null;

        removeUnused = await context.workspace
                .getConfiguration(confRemoveUnusedImportsOnSave) as bool? ??
            defaultRemoveUnusedImportsOnSave;
      }

      final source = await context.editor.getDocumentText(uri) ??
          await context.fs.readString(filePath);
      final result = syncImports(
        source,
        path: filePath,
        removeUnused: removeUnused,
      );
      if (result.source == source) {
        return ImportSyncResult(source: source);
      }

      final applied = await _applySource(
        uri: uri,
        filePath: filePath,
        original: source,
        updated: result.source,
      );
      if (!applied) {
        if (!quiet) {
          await context.window.showMessage(
            'Failed to update imports for ${path.basename(filePath)}.',
            type: MessageType.error,
          );
        }
        return null;
      }

      logService.info(
        'Synced imports in $filePath '
        '(+${result.added.length}/-${result.removed.length})',
      );
      return result;
    } catch (e, st) {
      logService.error('Import assist failed for $uri', e, st);
      if (!quiet) {
        await context.window.showMessage(
          'Import assist failed: $e',
          type: MessageType.error,
        );
      }
      return null;
    }
  }

  Future<bool> _applySource({
    required String uri,
    required String filePath,
    required String original,
    required String updated,
  }) async {
    final activeUri = await context.editor.getActiveDocumentUri();
    final activePath = activeUri == null ? null : _pathFromUri(activeUri);
    final isActive = activePath != null &&
        path.normalize(activePath) == path.normalize(filePath);

    if (isActive) {
      final lines = original.split('\n');
      final endLine = lines.isEmpty ? 0 : lines.length - 1;
      final endColumn = lines.isEmpty ? 0 : lines.last.length;
      await context.editor.replaceText(
        startLine: 0,
        startColumn: 0,
        endLine: endLine,
        endColumn: endColumn,
        newText: updated,
      );
      return true;
    }

    await context.fs.writeString(filePath, updated);
    return true;
  }

  String? _pathFromUri(String uriOrPath) {
    if (uriOrPath.isEmpty) return null;
    final parsed = Uri.tryParse(uriOrPath);
    if (parsed != null && parsed.isScheme('file')) {
      return parsed.toRealPath();
    }
    return uriOrPath;
  }

  Future<void> dispose() async {}
}
