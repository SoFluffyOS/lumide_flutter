import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/sdk/flutter_sdk_detection_service.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory temporaryHome;

  setUp(() async {
    temporaryHome = await Directory.systemTemp.createTemp(
      'lumide-flutter-sdk-detection-',
    );
  });

  tearDown(() async {
    if (await temporaryHome.exists()) {
      await temporaryHome.delete(recursive: true);
    }
  });

  test('discovers installed FVM and Puro SDKs without a workspace', () async {
    final fvmRoot = path.join(temporaryHome.path, 'custom-fvm');
    final fvmSdk = path.join(fvmRoot, 'versions', '3.32.0');
    await _createFlutterSdk(
      fvmSdk,
      flutterVersion: '3.32.0',
      dartVersion: '3.8.0',
      channel: 'stable',
    );
    final puroRoot = path.join(temporaryHome.path, 'custom-puro');
    final puroSdk = path.join(puroRoot, 'envs', 'work', 'flutter');
    await _createFlutterSdk(
      puroSdk,
      flutterVersion: '3.34.0-0.1.pre',
      dartVersion: '3.9.0',
      channel: 'beta',
    );
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: temporaryHome.path,
      environment: {
        'HOME': temporaryHome.path,
        'FVM_CACHE_PATH': fvmRoot,
        'PURO_ROOT': puroRoot,
      },
    );

    final installations = await service.discover(null);

    expect(installations, hasLength(2));
    final fvm = installations.singleWhere(
      (item) => item.managerId == LumideSdkManagerId.fvm,
    );
    expect(fvm.version, '3.32.0');
    expect(fvm.channel, 'stable');
    expect(fvm.rootPath, path.normalize(fvmSdk));
    expect(fvm.embeddedSdks.single.version, '3.8.0');
    final puro = installations.singleWhere(
      (item) => item.managerId == LumideSdkManagerId.puro,
    );
    expect(puro.version, '3.34.0-0.1.pre');
    expect(puro.displayName, 'Puro Flutter (work)');
  });

  test('reads FVM global cache config and nested fork versions', () async {
    final customRoot = path.join(temporaryHome.path, 'configured-fvm');
    final sdkRoot = path.join(customRoot, 'versions', 'acme', '3.30.0');
    await _createFlutterSdk(
      sdkRoot,
      flutterVersion: '3.30.0',
      dartVersion: '3.7.0',
    );
    final configFile = File(
      Platform.isMacOS
          ? path.join(
              temporaryHome.path,
              'Library',
              'Application Support',
              'fvm',
              '.fvmrc',
            )
          : Platform.isWindows
              ? path.join(temporaryHome.path, 'fvm', '.fvmrc')
              : path.join(temporaryHome.path, '.config', 'fvm', '.fvmrc'),
    );
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(jsonEncode({'cachePath': customRoot}));
    final environment = <String, String>{'HOME': temporaryHome.path};
    if (Platform.isWindows) {
      environment
        ..['USERPROFILE'] = temporaryHome.path
        ..['APPDATA'] = temporaryHome.path;
    }
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: temporaryHome.path,
      environment: environment,
    );

    final installations = await service.discover(null);

    expect(installations, hasLength(1));
    expect(installations.single.rootPath, path.normalize(sdkRoot));
    expect(installations.single.displayName, 'FVM Flutter (acme/3.30.0)');
  });

  for (final platform in const ['macos', 'windows', 'linux']) {
    test('reads a relative global FVM cache on $platform', () async {
      final home = path.join(temporaryHome.path, 'home');
      final appData = path.join(temporaryHome.path, 'app-data');
      final configHome = path.join(temporaryHome.path, 'config');
      final configPath = switch (platform) {
        'windows' => path.join(appData, 'fvm', '.fvmrc'),
        'macos' => path.join(
            home,
            'Library',
            'Application Support',
            'fvm',
            '.fvmrc',
          ),
        _ => path.join(configHome, 'fvm', '.fvmrc'),
      };
      await File(configPath).create(recursive: true);
      await File(configPath).writeAsString(
        jsonEncode({'cachePath': 'cache'}),
      );
      final sdkRoot = path.join(
        path.dirname(configPath),
        'cache',
        'versions',
        'stable',
      );
      await _createFlutterSdk(
        sdkRoot,
        flutterVersion: '3.36.0',
        dartVersion: '3.10.0',
        operatingSystem: platform,
      );
      final service = FlutterSdkDetectionService(
        _FakeContext(),
        homePath: home,
        operatingSystem: platform,
        environment: {
          'APPDATA': appData,
          'XDG_CONFIG_HOME': configHome,
        },
      );

      final installations = await service.discover(null);

      expect(installations, hasLength(1));
      expect(installations.single.rootPath, path.normalize(sdkRoot));
      expect(
        path.basename(installations.single.executables['flutter']!),
        platform == 'windows' ? 'flutter.bat' : 'flutter',
      );
      expect(
        path.basename(installations.single.executables['dart']!),
        platform == 'windows' ? 'dart.exe' : 'dart',
      );
    });
  }

  test('resolves a manager SDK when Flutter is not on PATH', () async {
    final fvmRoot = path.join(temporaryHome.path, 'fvm-cache');
    final sdkRoot = path.join(fvmRoot, 'versions', 'stable');
    await _createFlutterSdk(
      sdkRoot,
      flutterVersion: '3.32.0',
      dartVersion: '3.8.0',
      channel: 'stable',
    );
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: temporaryHome.path,
      environment: {
        'HOME': temporaryHome.path,
        'FVM_CACHE_PATH': fvmRoot,
      },
    );

    final resolution = await service.resolve(
      const LumideSdkResolveRequest(kind: LumideSdkKind.flutter),
    );

    expect(resolution, isNotNull);
    expect(
      resolution?.installation.source,
      LumideSdkSource.externalManager,
    );
    expect(resolution?.installation.managerId, LumideSdkManagerId.fvm);
    expect(
      resolution?.executable,
      path.join(sdkRoot, 'bin', _flutterFileName),
    );
  });

  test('does not inspect parent directories outside workspace boundary',
      () async {
    final workspace = path.join(temporaryHome.path, 'packages', 'app');
    await Directory(workspace).create(recursive: true);
    final fvmRoot = path.join(temporaryHome.path, '.cache', 'fvm');
    final sdkRoot = path.join(fvmRoot, 'versions', 'stable');
    await _createFlutterSdk(
      sdkRoot,
      flutterVersion: '3.32.1',
      dartVersion: '3.8.1',
    );
    await File(path.join(temporaryHome.path, '.fvmrc')).writeAsString(
      jsonEncode({'flutter': 'stable', 'cachePath': '.cache/fvm'}),
    );
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: path.join(temporaryHome.path, 'empty-home'),
      environment: const {},
    );

    final resolution = await service.resolve(
      LumideSdkResolveRequest(
        kind: LumideSdkKind.flutter,
        workspacePath: workspace,
      ),
    );

    expect(resolution, isNull);
  });

  test('discovers FVM configuration within workspace root', () async {
    final workspace = path.join(temporaryHome.path, 'app');
    await Directory(workspace).create(recursive: true);
    final fvmRoot = path.join(temporaryHome.path, '.cache', 'fvm');
    final sdkRoot = path.join(fvmRoot, 'versions', 'stable');
    await _createFlutterSdk(
      sdkRoot,
      flutterVersion: '3.32.1',
      dartVersion: '3.8.1',
    );
    await File(path.join(workspace, '.fvmrc')).writeAsString(
      jsonEncode({'flutter': 'stable', 'cachePath': fvmRoot}),
    );
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: path.join(temporaryHome.path, 'empty-home'),
      environment: const {},
    );

    final resolution = await service.resolve(
      LumideSdkResolveRequest(
        kind: LumideSdkKind.flutter,
        workspacePath: workspace,
      ),
    );

    expect(resolution?.installation.rootPath, path.normalize(sdkRoot));
    expect(
      resolution?.installation.managerScope,
      LumideSdkManagerScope.workspace,
    );
  });

  test(
      'discovers FVM configuration in workspace root when resolving subproject',
      () async {
    final workspace = path.join(temporaryHome.path, 'monorepo');
    final subproject = path.join(workspace, 'apps', 'mobile');
    await Directory(subproject).create(recursive: true);
    final fvmRoot = path.join(temporaryHome.path, '.cache', 'fvm');
    final sdkRoot = path.join(fvmRoot, 'versions', '3.44.9');
    await _createFlutterSdk(
      sdkRoot,
      flutterVersion: '3.44.9',
      dartVersion: '3.12.2',
    );
    await File(path.join(workspace, '.fvmrc')).writeAsString(
      jsonEncode({'flutter': '3.44.9', 'cachePath': fvmRoot}),
    );
    final service = FlutterSdkDetectionService(
      _FakeContext(workspaceRoot: workspace),
      homePath: path.join(temporaryHome.path, 'empty-home'),
      environment: const {},
    );

    final resolution = await service.resolve(
      LumideSdkResolveRequest(
        kind: LumideSdkKind.flutter,
        workspacePath: subproject,
      ),
    );

    expect(resolution?.installation.rootPath, path.normalize(sdkRoot));
    expect(resolution?.installation.version, '3.44.9');
    expect(
      resolution?.installation.managerScope,
      LumideSdkManagerScope.workspace,
    );
  });

  test('prefers the configured Puro default environment', () async {
    final puroRoot = path.join(temporaryHome.path, 'puro');
    await _createFlutterSdk(
      path.join(puroRoot, 'envs', 'alpha', 'flutter'),
      flutterVersion: '3.30.0',
      dartVersion: '3.7.0',
    );
    final defaultSdk = path.join(puroRoot, 'envs', 'work', 'flutter');
    await _createFlutterSdk(
      defaultSdk,
      flutterVersion: '3.34.0',
      dartVersion: '3.9.0',
    );
    await File(
      path.join(puroRoot, 'prefs.json'),
    ).writeAsString(jsonEncode({'defaultEnvironment': 'work'}));
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: temporaryHome.path,
      environment: {
        'HOME': temporaryHome.path,
        'PURO_ROOT': puroRoot,
      },
    );

    final resolution = await service.resolve(
      const LumideSdkResolveRequest(kind: LumideSdkKind.flutter),
    );

    expect(
      resolution?.installation.source,
      LumideSdkSource.externalManager,
    );
    expect(resolution?.installation.managerId, LumideSdkManagerId.puro);
    expect(resolution?.installation.rootPath, path.normalize(defaultSdk));
  });

  test('coalesces concurrent discovery for the same workspace', () async {
    final service = FlutterSdkDetectionService(
      _FakeContext(),
      homePath: temporaryHome.path,
      environment: const {},
    );

    final first = service.discover(null);
    final second = service.discover(null);

    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
  });
}

Future<void> _createFlutterSdk(
  String root, {
  required String flutterVersion,
  required String dartVersion,
  String? channel,
  String? operatingSystem,
}) async {
  final windows = (operatingSystem ?? Platform.operatingSystem) == 'windows';
  final flutter = File(
    path.join(root, 'bin', windows ? 'flutter.bat' : 'flutter'),
  );
  final dart = File(
    path.join(
      root,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      windows ? 'dart.exe' : 'dart',
    ),
  );
  await flutter.parent.create(recursive: true);
  await flutter.writeAsString('');
  await dart.parent.create(recursive: true);
  await dart.writeAsString('');
  await File(
    path.join(root, 'bin', 'cache', 'flutter.version.json'),
  ).writeAsString(
    jsonEncode({
      'frameworkVersion': flutterVersion,
      'dartSdkVersion': dartVersion,
      if (channel != null) 'channel': channel,
    }),
  );
}

String get _flutterFileName => Platform.isWindows ? 'flutter.bat' : 'flutter';

class _FakeContext implements LumideContext {
  _FakeContext({this.workspaceRoot});

  final String? workspaceRoot;

  @override
  final LumideFileSystem fs = _FakeFileSystem();

  @override
  late final LumideWorkspace workspace = _FakeWorkspace(workspaceRoot);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWorkspace implements LumideWorkspace {
  _FakeWorkspace(this.workspaceRoot);

  final String? workspaceRoot;

  @override
  Future<String?> getRootUri() async => workspaceRoot;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFileSystem implements LumideFileSystem {
  @override
  Future<bool> exists(String path) => FileSystemEntity.type(path).then(
        (type) => type != FileSystemEntityType.notFound,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
