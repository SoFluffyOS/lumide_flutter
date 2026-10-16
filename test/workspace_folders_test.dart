import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/launch_source_resolver.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/workspace_folders.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('workspaceFolderOf', () {
    test('reads an absolute folder from launch arguments', () {
      final folder = path.join(path.separator, 'work', 'api');
      expect(workspaceFolderOf({workspaceFolderArgument: folder}), folder);
    });

    test('ignores missing, relative and unresolved folders', () {
      expect(workspaceFolderOf(null), isNull);
      expect(workspaceFolderOf(const {}), isNull);
      expect(workspaceFolderOf(const {workspaceFolderArgument: 'api'}), isNull);
      expect(
        workspaceFolderOf(
            const {workspaceFolderArgument: r'${workspaceFolder}'}),
        isNull,
      );
    });
  });

  group('launchTargetsForFolder', () {
    final app = path.join(path.separator, 'work', 'app');
    final api = path.join(path.separator, 'work', 'api');
    final appMain = path.join(app, 'lib', 'main.dart');
    final apiMain = path.join(api, 'lib', 'main.dart');
    final outside = path.join(path.separator, 'elsewhere', 'main.dart');

    test('lists every target without a folder', () {
      expect(
        launchTargetsForFolder(
          [appMain, apiMain],
          folder: null,
          isFirstFolder: true,
        ),
        [appMain, apiMain],
      );
    });

    test('lists the targets inside the folder', () {
      expect(
        launchTargetsForFolder(
          [appMain, apiMain],
          folder: api,
          isFirstFolder: false,
        ),
        [apiMain],
      );
      expect(
        launchTargetsForFolder(
          [appMain, apiMain],
          folder: app,
          isFirstFolder: true,
          knownFolders: [api],
        ),
        [appMain],
      );
    });

    test('keeps a selected target outside every folder in the first folder',
        () {
      expect(
        launchTargetsForFolder(
          [appMain, outside],
          folder: app,
          isFirstFolder: true,
          selectedTarget: outside,
          knownFolders: [api],
        ),
        [appMain, outside],
      );
      expect(
        launchTargetsForFolder(
          [appMain, outside],
          folder: api,
          isFirstFolder: false,
          selectedTarget: outside,
        ),
        isEmpty,
      );
    });

    test('lists a selected target in another folder only there', () {
      expect(
        launchTargetsForFolder(
          [appMain, apiMain],
          folder: app,
          isFirstFolder: true,
          selectedTarget: apiMain,
          knownFolders: [api],
        ),
        [appMain],
      );
    });
  });

  group('ProjectService with a workspace folder', () {
    late Directory workspace;
    late String app;
    late String api;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('multi-root-');
      app = path.join(workspace.path, 'app');
      api = path.join(workspace.path, 'api');
      await _pubspec(app, 'name: app\nflutter:\n');
      await _pubspec(path.join(api, 'packages', 'client'), 'name: client\n');
      await _pubspec(
        path.join(api, 'apps', 'mobile'),
        'name: mobile\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );
    });

    tearDown(() => workspace.delete(recursive: true));

    test('finds the Flutter project of the folder', () async {
      final service = ProjectService(_Context(app, workspace.path));

      expect(await service.getProjectRoot(), app);
      expect(
        await service.getProjectRoot(null, api),
        path.join(api, 'apps', 'mobile'),
      );
    });

    test('finds the package of a file within the folder', () async {
      final service = ProjectService(_Context(app, workspace.path));

      expect(
        await service.getProjectRoot(
          path.join(api, 'packages', 'client', 'lib', 'client.dart'),
          api,
        ),
        path.join(api, 'packages', 'client'),
      );
    });

    test('ignores an unresolved folder', () async {
      final service = ProjectService(_Context(app, workspace.path));

      expect(await service.getProjectRoot(null, r'${workspaceFolder}'), app);
    });
  });

  group('SdkManager with a workspace folder', () {
    test('falls back on the workspace SDK of the folder', () async {
      final app = path.join(path.separator, 'work', 'app');
      final api = path.join(path.separator, 'work', 'api');
      final project = path.join(api, 'apps', 'mobile');
      final context = _Context(app, path.dirname(app), sdks: _Sdks());

      expect(
        await SdkManager(context).getFlutterCommand(
          project,
          workspaceFolder: api,
        ),
        ['fvm-$api', 'flutter'],
      );
      expect(
        await SdkManager(context).getFlutterCommand(project),
        ['fvm-$app', 'flutter'],
      );
    });
  });

  test('launch.json configurations run in the folder that holds them', () {
    const source = LumideLaunchSourceConfiguration(
      id: 'dev',
      name: 'Dev',
      providerId: 'flutter',
      config: {'target': 'lib/dev.dart'},
    );

    final arguments = resolveFlutterLaunchSource(
      source,
      projectRoot: '/workspace',
      selectedDeviceId: 'macos',
      deviceLabel: 'macOS',
      deviceTooltip: 'Local macOS',
      deviceIcon: 'laptop',
    ).configuration!.arguments;

    expect(arguments[workspaceFolderArgument], r'${workspaceFolder}');
    expect(arguments[relativeTargetArgument], 'lib/dev.dart');
  });

  test('absolute launch.json targets keep no relative target', () {
    const source = LumideLaunchSourceConfiguration(
      id: 'main',
      name: 'Main',
      providerId: 'flutter',
      config: {'target': r'${workspaceFolder}/lib/main.dart'},
    );

    final arguments = resolveFlutterLaunchSource(
      source,
      projectRoot: '/workspace',
      selectedDeviceId: 'macos',
      deviceLabel: 'macOS',
      deviceTooltip: 'Local macOS',
      deviceIcon: 'laptop',
    ).configuration!.arguments;

    expect(arguments, isNot(contains(relativeTargetArgument)));
  });
}

Future<void> _pubspec(String directory, String content) async {
  await Directory(directory).create(recursive: true);
  await File(path.join(directory, 'pubspec.yaml')).writeAsString(content);
}

class _Context implements LumideContext {
  _Context(String root, String filesRoot, {LumideSdks? sdks})
      : workspace = _Workspace(root, filesRoot),
        sdks = sdks ?? _Sdks();

  @override
  final LumideFileSystem fs = _FileSystem();
  @override
  final LumideWorkspace workspace;
  @override
  final LumideSdks sdks;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A workspace whose first folder is [root], and whose `findFiles` searches
/// every folder under [filesRoot], as Lumide does for several folders.
class _Workspace implements LumideWorkspace {
  _Workspace(this.root, this.filesRoot);

  final String root;
  final String filesRoot;

  @override
  Future<String?> getRootUri() async => root;

  @override
  Future<List<String>> findFiles(
    String glob, {
    String? folder,
    int? maxResults,
  }) async {
    final name = path.basename(glob);
    final directory = Directory(filesRoot);
    if (!await directory.exists()) return const [];
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File && path.basename(entity.path) == name)
        .map((entity) => Uri.file(entity.path).toString())
        .toList();
    return files..sort();
  }

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

/// Resolves a global SDK for a project and a workspace-scoped one, named
/// after the folder, for a workspace folder.
class _Sdks implements LumideSdks {
  @override
  Future<LumideSdkResolution?> resolve(LumideSdkResolveRequest request) async {
    final workspacePath = request.workspacePath!;
    final isProject = path.split(workspacePath).contains('mobile');
    return LumideSdkResolution(
      executable: isProject ? 'flutter' : 'fvm-$workspacePath',
      arguments: isProject ? const [] : const ['flutter'],
      installation: LumideSdkInstallation(
        id: workspacePath,
        kind: LumideSdkKind.flutter,
        providerId: 'flutter',
        version: '3.35.0',
        rootPath: workspacePath,
        source: LumideSdkSource.externalManager,
        managerScope: isProject
            ? LumideSdkManagerScope.global
            : LumideSdkManagerScope.workspace,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
