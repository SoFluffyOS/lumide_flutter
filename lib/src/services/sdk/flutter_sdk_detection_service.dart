import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

class FlutterSdkDetectionService {
  FlutterSdkDetectionService(
    this.context, {
    Map<String, String>? environment,
    String? homePath,
    String? operatingSystem,
  })  : _environment = environment ?? Platform.environment,
        _homePath = homePath,
        _operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final LumideContext context;
  final Map<String, String> _environment;
  final String? _homePath;
  final String _operatingSystem;
  final Map<String, Future<List<LumideSdkInstallation>>> _discoveries = {};
  final Map<String, Future<LumideSdkResolution?>> _resolutions = {};

  Future<List<LumideSdkInstallation>> discover(String? workspacePath) {
    final key = path.normalize(workspacePath ?? '');
    final existing = _discoveries[key];
    if (existing != null) return existing;
    late final Future<List<LumideSdkInstallation>> discovery;
    discovery = _discover(workspacePath).whenComplete(() {
      if (identical(_discoveries[key], discovery)) _discoveries.remove(key);
    });
    _discoveries[key] = discovery;
    return discovery;
  }

  Future<List<LumideSdkInstallation>> _discover(
    String? workspacePath,
  ) async {
    final installations = <String, LumideSdkInstallation>{};

    Future<void> add(LumideSdkInstallation? installation) async {
      if (installation == null) return;
      final canonicalRoot = await _canonicalPath(installation.rootPath);
      installations.putIfAbsent(canonicalRoot, () => installation);
    }

    // A project-pinned environment is the most relevant result and should win
    // when its SDK is also present in a global manager cache.
    await add(await _discoverWorkspaceManager(workspacePath));
    final fvm = _discoverFvmInstallations(workspacePath);
    final puro = _discoverPuroInstallations();
    final system = _discoverCommand(
      'flutter',
      LumideSdkSource.system,
      workingDirectory: workspacePath,
    );
    for (final installation in await fvm) {
      await add(installation);
    }
    for (final installation in await puro) {
      await add(installation);
    }
    await add(await system);
    return installations.values.toList();
  }

  Future<LumideSdkResolution?> resolve(
    LumideSdkResolveRequest request,
  ) {
    final key = path.normalize(request.workspacePath ?? '');
    final existing = _resolutions[key];
    if (existing != null) return existing;
    late final Future<LumideSdkResolution?> resolution;
    resolution = _resolve(request).whenComplete(() {
      if (identical(_resolutions[key], resolution)) _resolutions.remove(key);
    });
    _resolutions[key] = resolution;
    return resolution;
  }

  Future<LumideSdkResolution?> _resolve(
    LumideSdkResolveRequest request,
  ) async {
    final workspacePath = request.workspacePath;
    final manager = await _discoverWorkspaceManager(workspacePath);
    if (manager != null) return _resolutionFor(manager);
    final system = await _discoverCommand(
      'flutter',
      LumideSdkSource.system,
      workingDirectory: workspacePath,
    );
    if (system != null) return _resolutionFor(system);

    // A manager-installed SDK is still useful when no workspace is open and
    // neither manager shims nor Flutter itself are on PATH.
    final fvm = await _discoverPreferredFvm(workspacePath);
    if (fvm != null) return _resolutionFor(fvm);
    final puro = await _discoverPreferredPuro();
    if (puro != null) return _resolutionFor(puro);
    return null;
  }

  Future<LumideSdkInstallation?> _discoverPreferredFvm(
    String? workspacePath,
  ) async {
    for (final fvmRoot in await _fvmRoots(workspacePath)) {
      final preferred = await _installationFromRoot(
        path.join(fvmRoot, 'default'),
        LumideSdkSource.externalManager,
        displayName: 'FVM Flutter (default)',
        managerId: LumideSdkManagerId.fvm,
        managerScope: LumideSdkManagerScope.global,
      );
      if (preferred != null) return preferred;
      final versions = Directory(path.join(fvmRoot, 'versions'));
      final candidate = await _firstSdkDirectory(versions, nestedLevels: 1);
      if (candidate == null) continue;
      final relativeName = path.posix.joinAll(
        path.split(path.relative(candidate.path, from: versions.path)),
      );
      final fallback = await _installationFromRoot(
        candidate.path,
        LumideSdkSource.externalManager,
        displayName: 'FVM Flutter ($relativeName)',
        fallbackVersion: relativeName,
        managerId: LumideSdkManagerId.fvm,
        managerScope: LumideSdkManagerScope.global,
      );
      if (fallback != null) return fallback;
    }
    return null;
  }

  Future<LumideSdkInstallation?> _discoverPreferredPuro() async {
    for (final puroRoot in _puroRoots()) {
      final defaultName = await _readJsonString(
            path.join(puroRoot, 'prefs.json'),
            'defaultEnvironment',
          ) ??
          await _readTrimmed(path.join(puroRoot, 'default_env')) ??
          'stable';
      for (final environmentName in {defaultName, 'default'}) {
        final preferred = await _installationFromRoot(
          path.join(puroRoot, 'envs', environmentName, 'flutter'),
          LumideSdkSource.externalManager,
          displayName: 'Puro Flutter ($environmentName)',
          managerId: LumideSdkManagerId.puro,
          managerScope: LumideSdkManagerScope.global,
        );
        if (preferred != null) return preferred;
      }
      final environments = [
        ...await _childDirectories(Directory(path.join(puroRoot, 'envs'))),
      ]..sort((left, right) => left.path.compareTo(right.path));
      for (final environment in environments) {
        final name = path.basename(environment.path);
        final fallback = await _installationFromRoot(
          path.join(environment.path, 'flutter'),
          LumideSdkSource.externalManager,
          displayName: 'Puro Flutter ($name)',
          managerId: LumideSdkManagerId.puro,
          managerScope: LumideSdkManagerScope.global,
        );
        if (fallback != null) return fallback;
      }
    }
    return null;
  }

  Future<LumideSdkInstallation?> _discoverWorkspaceManager(
    String? workspacePath,
  ) async {
    if (workspacePath == null || workspacePath.isEmpty) return null;
    final fvmProject = await _findFvmProject(workspacePath);
    if (fvmProject != null) {
      final linkedSdk = await _installationFromRoot(
        path.join(fvmProject.root, '.fvm', 'flutter_sdk'),
        LumideSdkSource.externalManager,
        displayName: 'FVM Flutter',
        managerId: LumideSdkManagerId.fvm,
        managerScope: LumideSdkManagerScope.workspace,
      );
      if (linkedSdk != null) return linkedSdk;
      final version = await _readJsonString(fvmProject.fvmrc, 'flutter') ??
          await _readJsonString(
            fvmProject.legacyConfig,
            'flutterSdkVersion',
          );
      if (version != null) {
        for (final root in await _fvmRoots(workspacePath)) {
          final installation = await _installationFromRoot(
            path.join(root, 'versions', version),
            LumideSdkSource.externalManager,
            displayName: 'FVM Flutter ($version)',
            fallbackVersion: version,
            managerId: LumideSdkManagerId.fvm,
            managerScope: LumideSdkManagerScope.workspace,
          );
          if (installation != null) return installation;
        }
      }
      return _discoverCommand(
        'fvm',
        LumideSdkSource.externalManager,
        proxyArgument: 'flutter',
        workingDirectory: workspacePath,
        managerId: LumideSdkManagerId.fvm,
        managerScope: LumideSdkManagerScope.workspace,
      );
    }
    final puroConfigPath = await _findAncestorFile(workspacePath, '.puro.json');
    if (puroConfigPath == null) return null;

    final environmentName = await _readJsonString(puroConfigPath, 'env');
    if (environmentName != null) {
      for (final root in _puroRoots()) {
        final installation = await _installationFromRoot(
          path.join(root, 'envs', environmentName, 'flutter'),
          LumideSdkSource.externalManager,
          displayName: 'Puro Flutter ($environmentName)',
          managerId: LumideSdkManagerId.puro,
          managerScope: LumideSdkManagerScope.workspace,
        );
        if (installation != null) return installation;
      }
    }
    return _discoverCommand(
      'puro',
      LumideSdkSource.externalManager,
      proxyArgument: 'flutter',
      workingDirectory: workspacePath,
      managerId: LumideSdkManagerId.puro,
      managerScope: LumideSdkManagerScope.workspace,
    );
  }

  Future<List<LumideSdkInstallation>> _discoverFvmInstallations(
    String? workspacePath,
  ) async {
    final installations = <LumideSdkInstallation>[];
    final seenRoots = <String>{};
    for (final fvmRoot in await _fvmRoots(workspacePath)) {
      final versionsDirectory = Directory(path.join(fvmRoot, 'versions'));
      final defaultRoot = await _canonicalPath(path.join(fvmRoot, 'default'));
      final candidates = await _sdkDirectories(
        versionsDirectory,
        nestedLevels: 1,
      );
      final rootInstallations = <LumideSdkInstallation>[];
      for (final candidate in candidates) {
        final canonicalRoot = await _canonicalPath(candidate.path);
        if (!seenRoots.add(canonicalRoot)) continue;
        final relativeName = path.posix.joinAll(
          path.split(
            path.relative(
              candidate.path,
              from: versionsDirectory.path,
            ),
          ),
        );
        final installation = await _installationFromRoot(
          candidate.path,
          LumideSdkSource.externalManager,
          displayName: 'FVM Flutter ($relativeName)',
          fallbackVersion: relativeName,
          managerId: LumideSdkManagerId.fvm,
          managerScope: LumideSdkManagerScope.global,
        );
        if (installation == null) continue;
        if (path.equals(canonicalRoot, defaultRoot)) {
          rootInstallations.insert(0, installation);
        } else {
          rootInstallations.add(installation);
        }
      }
      installations.addAll(rootInstallations);
    }
    return installations;
  }

  Future<List<LumideSdkInstallation>> _discoverPuroInstallations() async {
    final installations = <LumideSdkInstallation>[];
    final seenRoots = <String>{};
    for (final puroRoot in _puroRoots()) {
      final environmentsDirectory = Directory(path.join(puroRoot, 'envs'));
      final defaultName = await _readJsonString(
            path.join(puroRoot, 'prefs.json'),
            'defaultEnvironment',
          ) ??
          await _readTrimmed(path.join(puroRoot, 'default_env')) ??
          'stable';
      final defaultRoot = await _canonicalPath(
        path.join(environmentsDirectory.path, 'default', 'flutter'),
      );
      final environments = [
        ...await _childDirectories(environmentsDirectory),
      ];
      environments.sort((left, right) => left.path.compareTo(right.path));
      final rootInstallations = <LumideSdkInstallation>[];
      for (final environment in environments) {
        final environmentName = path.basename(environment.path);
        final flutterRoot = path.join(environment.path, 'flutter');
        final canonicalRoot = await _canonicalPath(flutterRoot);
        if (!seenRoots.add(canonicalRoot)) continue;
        final installation = await _installationFromRoot(
          flutterRoot,
          LumideSdkSource.externalManager,
          displayName: 'Puro Flutter ($environmentName)',
          managerId: LumideSdkManagerId.puro,
          managerScope: LumideSdkManagerScope.global,
        );
        if (installation == null) continue;
        if (environmentName == defaultName ||
            path.equals(canonicalRoot, defaultRoot)) {
          rootInstallations.insert(0, installation);
        } else {
          rootInstallations.add(installation);
        }
      }
      installations.addAll(rootInstallations);
    }
    return installations;
  }

  Future<List<String>> _fvmRoots(String? workspacePath) async {
    final roots = <String>[];
    void add(String? value, {String? relativeTo}) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty) return;
      final resolved = !path.isAbsolute(trimmed) && relativeTo != null
          ? path.join(relativeTo, trimmed)
          : trimmed;
      final normalized = path.normalize(resolved);
      if (!roots.any((root) => path.equals(root, normalized))) {
        roots.add(normalized);
      }
    }

    if (workspacePath != null && workspacePath.isNotEmpty) {
      final fvmProject = await _findFvmProject(workspacePath);
      add(
        await _readJsonString(fvmProject?.fvmrc, 'cachePath'),
        relativeTo: fvmProject?.root,
      );
    }
    add(_environment['FVM_CACHE_PATH']);
    add(_environment['FVM_HOME']);
    final globalConfig = _fvmGlobalConfigPath;
    add(
      await _readJsonString(globalConfig, 'cachePath'),
      relativeTo: globalConfig == null ? null : path.dirname(globalConfig),
    );
    final home = _homeDirectory;
    if (home != null) {
      add(path.join(home, 'fvm'));
      // Older installations and third-party setup scripts commonly used this.
      add(path.join(home, '.fvm'));
    }
    return roots;
  }

  Iterable<String> _puroRoots() sync* {
    final roots = <String>[];
    void add(String? value) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty) return;
      final normalized = path.normalize(trimmed);
      if (!roots.any((root) => path.equals(root, normalized))) {
        roots.add(normalized);
      }
    }

    final puroFlutterBin = _environment['PURO_FLUTTER_BIN'];
    if (puroFlutterBin != null && puroFlutterBin.trim().isNotEmpty) {
      add(
        path.dirname(
          path.dirname(path.dirname(path.dirname(puroFlutterBin))),
        ),
      );
    }
    add(_environment['PURO_ROOT']);
    final home = _homeDirectory;
    if (home != null) add(path.join(home, '.puro'));
    yield* roots;
  }

  String? get _homeDirectory {
    final override = _homePath?.trim();
    if (override != null && override.isNotEmpty) return override;
    final value = _isWindows
        ? _environment['USERPROFILE'] ?? _environment['UserProfile']
        : _environment['HOME'];
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String? get _fvmGlobalConfigPath {
    final home = _homeDirectory;
    if (_isWindows) {
      final appData = _environment['APPDATA'];
      return appData == null || appData.isEmpty
          ? null
          : path.join(appData, 'fvm', '.fvmrc');
    }
    if (home == null) return null;
    if (_isMacOS) {
      return path.join(home, 'Library', 'Application Support', 'fvm', '.fvmrc');
    }
    final configHome = _environment['XDG_CONFIG_HOME'];
    return path.join(
      configHome == null || configHome.isEmpty
          ? path.join(home, '.config')
          : configHome,
      'fvm',
      '.fvmrc',
    );
  }

  Future<List<Directory>> _sdkDirectories(
    Directory directory, {
    required int nestedLevels,
  }) async {
    final result = <Directory>[];
    for (final child in await _childDirectories(directory)) {
      if (path.basename(child.path).startsWith('.')) continue;
      if (await _looksLikeFlutterSdk(child)) {
        result.add(child);
      } else if (nestedLevels > 0) {
        result.addAll(
          await _sdkDirectories(child, nestedLevels: nestedLevels - 1),
        );
      }
    }
    return result;
  }

  Future<Directory?> _firstSdkDirectory(
    Directory directory, {
    required int nestedLevels,
  }) async {
    final children = [...await _childDirectories(directory)]
      ..sort((left, right) => left.path.compareTo(right.path));
    for (final child in children) {
      if (path.basename(child.path).startsWith('.')) continue;
      if (await _looksLikeFlutterSdk(child)) return child;
      if (nestedLevels > 0) {
        final nested = await _firstSdkDirectory(
          child,
          nestedLevels: nestedLevels - 1,
        );
        if (nested != null) return nested;
      }
    }
    return null;
  }

  Future<List<Directory>> _childDirectories(Directory directory) async {
    try {
      if (!await directory.exists()) return const [];
      return await directory
          .list(followLinks: true)
          .where((entity) => entity is Directory)
          .cast<Directory>()
          .toList();
    } on FileSystemException {
      return const [];
    }
  }

  Future<bool> _looksLikeFlutterSdk(Directory directory) {
    return File(path.join(directory.path, 'bin', _flutterFileName)).exists();
  }

  Future<LumideSdkInstallation?> _installationFromRoot(
    String root,
    LumideSdkSource source, {
    required String displayName,
    String? fallbackVersion,
    LumideSdkManagerId? managerId,
    LumideSdkManagerScope? managerScope,
    Map<String, Object?> metadata = const {},
  }) async {
    final normalizedRoot = path.normalize(root);
    final flutterExecutable = path.join(
      normalizedRoot,
      'bin',
      _flutterFileName,
    );
    if (!await File(flutterExecutable).exists()) return null;

    final versionInfo = await _readFlutterMetadata(normalizedRoot);
    final dartExecutable = path.join(
      normalizedRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      _dartFileName,
    );
    final flutterVersion = versionInfo.flutterVersion ??
        await _readTrimmed(path.join(normalizedRoot, 'version')) ??
        fallbackVersion ??
        'Unknown';
    final dartVersion = versionInfo.dartVersion ??
        await _readTrimmed(
          path.join(
            normalizedRoot,
            'bin',
            'cache',
            'dart-sdk',
            'version',
          ),
        ) ??
        'Unknown';
    final channel = versionInfo.channel ?? _channelFrom(fallbackVersion);
    return LumideSdkInstallation(
      id: '${source.name}-$flutterVersion-${normalizedRoot.hashCode}',
      providerId: 'flutter',
      kind: LumideSdkKind.flutter,
      version: flutterVersion,
      rootPath: normalizedRoot,
      source: source,
      channel: channel,
      displayName: displayName,
      managerId: managerId,
      managerScope: managerScope,
      executables: {
        'flutter': flutterExecutable,
        if (await File(dartExecutable).exists()) 'dart': dartExecutable,
      },
      embeddedSdks: [
        LumideEmbeddedSdk(
          kind: LumideSdkKind.dart,
          version: dartVersion,
          rootPath: 'bin/cache/dart-sdk',
          executables: {'dart': path.join('bin', _dartFileName)},
        ),
      ],
      metadata: metadata,
    );
  }

  Future<_FlutterVersionInfo> _readFlutterMetadata(String root) async {
    final metadataPath = path.join(
      root,
      'bin',
      'cache',
      'flutter.version.json',
    );
    try {
      final contents = await File(metadataPath).readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map) return const _FlutterVersionInfo();
      return _FlutterVersionInfo(
        flutterVersion: _nonEmpty(
          decoded['flutterVersion']?.toString() ??
              decoded['frameworkVersion']?.toString(),
        ),
        dartVersion: _nonEmpty(decoded['dartSdkVersion']?.toString()),
        channel: _nonEmpty(decoded['channel']?.toString()),
      );
    } on FileSystemException {
      return const _FlutterVersionInfo();
    } on FormatException {
      return const _FlutterVersionInfo();
    }
  }

  Future<String?> _readJsonString(String? filePath, String key) async {
    if (filePath == null) return null;
    try {
      final decoded = jsonDecode(await File(filePath).readAsString());
      if (decoded is! Map) return null;
      return _nonEmpty(decoded[key]?.toString());
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readTrimmed(String filePath) async {
    try {
      return _nonEmpty(await File(filePath).readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveWorkspaceBoundary(String workspacePath) async {
    final normalized = path.normalize(path.absolute(workspacePath));
    try {
      final rootUri = await context.workspace.getRootUri();
      if (rootUri case final root? when root.isNotEmpty) {
        final normalizedRoot = path.normalize(path.absolute(root));
        final isContained = path.equals(normalizedRoot, normalized) ||
            path.isWithin(normalizedRoot, normalized);
        if (isContained) return normalizedRoot;
      }
    } catch (_) {}
    return normalized;
  }

  Future<({String root, String? fvmrc, String? legacyConfig})?> _findFvmProject(
      String workspacePath) async {
    final boundary = await _resolveWorkspaceBoundary(workspacePath);
    for (final directory
        in _ancestorDirectories(workspacePath, stopAt: boundary)) {
      final fvmrc = path.join(directory, '.fvmrc');
      final legacyConfig = path.join(
        directory,
        '.fvm',
        'fvm_config.json',
      );
      final results = await Future.wait([
        _safeFileExists(fvmrc),
        _safeFileExists(legacyConfig),
      ]);
      final hasFvmrc = results[0];
      final hasLegacy = results[1];
      if (hasFvmrc || hasLegacy) {
        return (
          root: directory,
          fvmrc: switch (hasFvmrc) {
            true => fvmrc,
            false => null,
          },
          legacyConfig: switch (hasLegacy) {
            true => legacyConfig,
            false => null,
          },
        );
      }
    }
    return null;
  }

  Future<String?> _findAncestorFile(
    String workspacePath,
    String relativePath,
  ) async {
    final boundary = await _resolveWorkspaceBoundary(workspacePath);
    for (final directory
        in _ancestorDirectories(workspacePath, stopAt: boundary)) {
      final candidate = path.join(directory, relativePath);
      if (await _safeFileExists(candidate)) return candidate;
    }
    return null;
  }

  Future<bool> _safeFileExists(String filePath) async {
    try {
      return await context.fs.exists(filePath);
    } catch (_) {
      return false;
    }
  }

  Iterable<String> _ancestorDirectories(
    String startPath, {
    String? stopAt,
  }) sync* {
    final root = switch (stopAt) {
      final stop? when stop.isNotEmpty => path.normalize(path.absolute(stop)),
      _ => null,
    };
    var current = path.normalize(path.absolute(startPath));
    while (true) {
      yield current;
      if (root case final boundary?) {
        if (path.equals(current, boundary) ||
            !path.isWithin(boundary, current)) {
          return;
        }
      }
      final parent = path.dirname(current);
      if (path.equals(parent, current)) return;
      current = parent;
    }
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String? _channelFrom(String? value) {
    final normalized = value?.trim().toLowerCase();
    return const {'stable', 'beta', 'dev', 'master', 'main'}
            .contains(normalized)
        ? normalized
        : null;
  }

  Future<String> _canonicalPath(String value) async {
    try {
      return path.normalize(await Directory(value).resolveSymbolicLinks());
    } on FileSystemException {
      return path.normalize(path.absolute(value));
    }
  }

  bool get _isWindows => _operatingSystem == 'windows';

  bool get _isMacOS => _operatingSystem == 'macos';

  String get _flutterFileName => _isWindows ? 'flutter.bat' : 'flutter';

  String get _dartFileName => _isWindows ? 'dart.exe' : 'dart';

  Future<LumideSdkInstallation?> _discoverCommand(
    String command,
    LumideSdkSource source, {
    String? proxyArgument,
    String? workingDirectory,
    LumideSdkManagerId? managerId,
    LumideSdkManagerScope? managerScope,
  }) async {
    final executable = await _resolveExecutable(command);
    if (executable == null) return null;
    final arguments = [if (proxyArgument != null) proxyArgument];
    final versionInfo = await _getVersionInfo(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    final flutterRoot = versionInfo.flutterRoot;
    final rootPath = flutterRoot != null && path.isAbsolute(flutterRoot)
        ? path.normalize(flutterRoot)
        : path.dirname(executable);
    final sdkFlutterExecutable = path.join(
      rootPath,
      'bin',
      _flutterFileName,
    );
    final canUseSdkExecutable = await File(sdkFlutterExecutable).exists();
    final resolvedExecutable =
        canUseSdkExecutable ? sdkFlutterExecutable : executable;
    final resolvedArguments =
        canUseSdkExecutable ? const <String>[] : arguments;
    final dartExecutable = path.join(
      rootPath,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      _dartFileName,
    );
    return LumideSdkInstallation(
      id: '${source.name}-${versionInfo.flutterVersion}-${rootPath.hashCode}',
      providerId: 'flutter',
      kind: LumideSdkKind.flutter,
      version: versionInfo.flutterVersion ?? 'Unknown',
      rootPath: rootPath,
      source: source,
      channel: versionInfo.channel,
      displayName: switch (managerId) {
        LumideSdkManagerId.fvm => 'FVM Flutter',
        LumideSdkManagerId.puro => 'Puro Flutter',
        _ => 'System Flutter',
      },
      managerId: managerId,
      managerScope: managerScope,
      executables: {
        'flutter': resolvedExecutable,
        if (await File(dartExecutable).exists()) 'dart': dartExecutable,
      },
      embeddedSdks: [
        LumideEmbeddedSdk(
          kind: LumideSdkKind.dart,
          version: versionInfo.dartVersion ?? 'Unknown',
          rootPath: 'bin/cache/dart-sdk',
          executables: {'dart': path.join('bin', _dartFileName)},
        ),
      ],
      metadata: {
        if (resolvedArguments.isNotEmpty) 'arguments': resolvedArguments,
      },
    );
  }

  LumideSdkResolution _resolutionFor(LumideSdkInstallation installation) {
    final executable = installation.executables['flutter'] ?? '';
    final rawArguments = installation.metadata['arguments'];
    final arguments = rawArguments is List
        ? rawArguments.map((argument) => argument.toString()).toList()
        : const <String>[];
    return LumideSdkResolution(
      installation: installation,
      executable: executable,
      arguments: arguments,
      environment: {'FLUTTER_ROOT': installation.rootPath},
    );
  }

  Future<String?> _resolveExecutable(String command) async {
    try {
      final resolver = _isWindows ? 'where' : 'which';
      final result = await context.shell.run(resolver, [command]);
      if (result.exitCode != 0) return null;
      final candidates = result.stdout
          .trim()
          .split(RegExp(r'[\r\n]+'))
          .map((candidate) => candidate.trim())
          .where((candidate) => candidate.isNotEmpty)
          .toList();
      if (!_isWindows) return candidates.firstOrNull;
      for (final candidate in candidates) {
        final lower = candidate.toLowerCase();
        if (lower.endsWith('.exe') ||
            lower.endsWith('.bat') ||
            lower.endsWith('.cmd')) {
          return candidate;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<_FlutterVersionInfo> _getVersionInfo(
    String executable,
    List<String> prefixArguments, {
    String? workingDirectory,
  }) async {
    try {
      final result = await Process.run(
        executable,
        [...prefixArguments, '--version', '--machine'],
        workingDirectory: workingDirectory,
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return const _FlutterVersionInfo();
      final decoded = jsonDecode(result.stdout.toString());
      if (decoded is! Map) return const _FlutterVersionInfo();
      return _FlutterVersionInfo(
        flutterVersion: _nonEmpty(decoded['frameworkVersion']?.toString()),
        dartVersion: _nonEmpty(decoded['dartSdkVersion']?.toString()),
        channel: _nonEmpty(decoded['channel']?.toString()),
        flutterRoot: _nonEmpty(decoded['flutterRoot']?.toString()),
      );
    } catch (_) {
      return const _FlutterVersionInfo();
    }
  }
}

class _FlutterVersionInfo {
  const _FlutterVersionInfo({
    this.flutterVersion,
    this.dartVersion,
    this.channel,
    this.flutterRoot,
  });

  final String? flutterVersion;
  final String? dartVersion;
  final String? channel;
  final String? flutterRoot;
}
