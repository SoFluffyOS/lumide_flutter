import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('uses the Pub workspace root for a nested preview package', () async {
    final workspace =
        await Directory.systemTemp.createTemp('preview-workspace-');
    addTearDown(() => workspace.delete(recursive: true));
    final app = Directory(path.join(workspace.path, 'apps', 'example'));
    await app.create(recursive: true);
    await File(path.join(workspace.path, 'pubspec.yaml')).writeAsString(
        'name: example_workspace\nworkspace:\n  - apps/example\n');
    await File(path.join(app.path, 'pubspec.yaml'))
        .writeAsString('name: example\nresolution: workspace\n');

    final service = ProjectService(_Context(workspace.path));
    expect(
      await service
          .getWidgetPreviewRoot(path.join(app.path, 'lib', 'main.dart')),
      workspace.path,
    );
  });
}

class _Context implements LumideContext {
  _Context(String root) : workspace = _Workspace(root);

  @override
  final LumideFileSystem fs = _FileSystem();
  @override
  final LumideWorkspace workspace;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Workspace implements LumideWorkspace {
  _Workspace(this.root);
  final String root;
  @override
  Future<String?> getRootUri() async => root;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FileSystem implements LumideFileSystem {
  @override
  Future<bool> exists(String filePath) => File(filePath).exists();
  @override
  Future<String> readString(String filePath) => File(filePath).readAsString();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
