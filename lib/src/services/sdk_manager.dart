import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
import 'package:path/path.dart' as path;

class SdkManager {
  SdkManager(this.context,
      {this.versionCheckTimeout = const Duration(seconds: 20)});

  final LumideContext context;
  final Duration versionCheckTimeout;
  final Map<String, Future<bool>> _widgetPreviewSupport = {};

  Future<String?> _workspaceRoot([String? workspaceFolder]) async {
    if (workspaceFolder != null && workspaceFolder.isNotEmpty) {
      return path.normalize(path.absolute(workspaceFolder));
    }
    try {
      final root = await context.workspace.getRootUri();
      if (root case final uri? when uri.isNotEmpty) {
        return path.normalize(path.absolute(uri));
      }
    } catch (_) {}
    return null;
  }

  /// The command that runs Flutter for [projectRoot].
  ///
  /// A project below its workspace folder falls back on the folder's
  /// workspace SDK, such as from the folder's `.fvmrc`. [workspaceFolder] is
  /// that folder; without it, the first folder is used.
  Future<List<String>> getFlutterCommand(
    String projectRoot, {
    String? workspaceFolder,
  }) async {
    try {
      final resolved = await _resolveFlutter(projectRoot, workspaceFolder);
      if (resolved case (request: _, :final resolution)) {
        return [resolution.executable, ...resolution.arguments];
      }
    } catch (_) {
      // Host resolution failed or threw. Fall back to legacy discovery.
    }
    return _legacyFlutterCommand(projectRoot, workspaceFolder);
  }

  /// Starts `flutter <arguments>` with the SDK [getFlutterCommand] picks.
  ///
  /// Lumide starts the process (`sdks.spawn`) so it runs under the host's SDK
  /// policy. Hosts without it, or without a resolved SDK, fall back to a
  /// local process.
  Future<SdkProcess> startFlutter(
    String projectRoot,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? workspaceFolder,
  }) async {
    try {
      final resolved = await _resolveFlutter(projectRoot, workspaceFolder);
      if (resolved case (:final request, resolution: _)) {
        return await _hostProcesses.spawn(
          () => context.sdks.spawn(
            request,
            arguments,
            workingDirectory: workingDirectory ?? projectRoot,
            environment: environment,
          ),
        );
      }
    } catch (_) {
      // Fall back to a local process below.
    }
    final command = await getFlutterCommand(
      projectRoot,
      workspaceFolder: workspaceFolder,
    );
    return LocalSdkProcess.start(
      [...command, ...arguments],
      workingDirectory: workingDirectory ?? projectRoot,
      environment: environment,
    );
  }

  late final HostProcessHub _hostProcesses = HostProcessHub(context.shell);

  void dispose() => _hostProcesses.dispose();

  /// Resolves the Flutter SDK for [projectRoot]. A nested package uses the
  /// workspace root's SDK when that one is pinned to the workspace.
  Future<
      ({
        LumideSdkResolveRequest request,
        LumideSdkResolution resolution,
      })?> _resolveFlutter(
    String projectRoot, [
    String? workspaceFolder,
  ]) async {
    final request = _flutterRequest(projectRoot);
    final resolution = await context.sdks.resolve(request);
    if (resolution == null || resolution.executable.isEmpty) return null;

    final isWorkspaceScoped =
        resolution.installation.managerScope == LumideSdkManagerScope.workspace;
    final wsRoot = await _workspaceRoot(workspaceFolder);
    final normalizedProject = path.normalize(path.absolute(projectRoot));
    final isAtWorkspaceRoot = switch (wsRoot) {
      final root? => path.equals(root, normalizedProject),
      _ => true,
    };
    if (isWorkspaceScoped || isAtWorkspaceRoot) {
      return (request: request, resolution: resolution);
    }

    if (wsRoot case final root?) {
      final wsRequest = _flutterRequest(root);
      final wsResolution = await context.sdks.resolve(wsRequest);
      if (wsResolution case final wsRes? when wsRes.executable.isNotEmpty) {
        final isWsScoped =
            wsRes.installation.managerScope == LumideSdkManagerScope.workspace;
        if (isWsScoped) return (request: wsRequest, resolution: wsRes);
      }
    }

    return (request: request, resolution: resolution);
  }

  LumideSdkResolveRequest _flutterRequest(String workspacePath) =>
      LumideSdkResolveRequest(
        kind: LumideSdkKind.flutter,
        providerId: 'flutter',
        workspacePath: workspacePath,
        executable: 'flutter',
      );

  Future<List<String>> _legacyFlutterCommand(
    String projectRoot, [
    String? workspaceFolder,
  ]) async {
    final searchDirs = <String>[projectRoot];
    final wsRoot = await _workspaceRoot(workspaceFolder);
    final normalizedProject = path.normalize(path.absolute(projectRoot));
    if (wsRoot case final root? when !path.equals(root, normalizedProject)) {
      searchDirs.add(root);
    }

    for (final dir in searchDirs) {
      final fvmConfig = path.join(dir, '.fvm', 'fvm_config.json');
      final fvmrc = path.join(dir, '.fvmrc');
      final results = await Future.wait([
        context.fs.exists(fvmConfig),
        context.fs.exists(fvmrc),
      ]);
      if (results[0] || results[1]) {
        final resolved = await _resolveViaShell('fvm');
        if (resolved case final cmd?) return [cmd, 'flutter'];
      }

      final puroJson = path.join(dir, '.puro.json');
      if (await context.fs.exists(puroJson)) {
        final resolved = await _resolveViaShell('puro');
        if (resolved case final cmd?) return [cmd, 'flutter'];
      }
    }

    final resolved = await _resolveViaShell('flutter');
    return [
      switch (resolved) {
        final cmd? => cmd,
        _ => 'flutter',
      },
    ];
  }

  Future<String?> _resolveViaShell(String command) async {
    try {
      final resolver = switch (Platform.isWindows) {
        true => 'where',
        false => 'which',
      };
      final result = await context.shell.run(resolver, [command]);
      if (result.exitCode != 0) return null;
      final candidates = result.stdout
          .trim()
          .split(RegExp(r'[\r\n]+'))
          .map((candidate) => candidate.trim())
          .where((candidate) => candidate.isNotEmpty)
          .toList();
      if (!Platform.isWindows) return candidates.firstOrNull;
      for (final candidate in candidates) {
        final lower = candidate.toLowerCase();
        final isExecutable = lower.endsWith('.exe') ||
            lower.endsWith('.bat') ||
            lower.endsWith('.cmd');
        if (isExecutable) {
          return candidate;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<bool> supportsWidgetPreview(String projectRoot) async {
    final command = await getFlutterCommand(projectRoot);
    final key = '$projectRoot\u0000${command.join('\u0000')}';
    final cached = _widgetPreviewSupport[key];
    if (cached != null) return cached;
    final check = _checkWidgetPreviewSupport(command, projectRoot);
    _widgetPreviewSupport[key] = check;
    return check;
  }

  Future<bool> _checkWidgetPreviewSupport(
      List<String> command, String projectRoot) async {
    final resolvedVersion = await _resolvedVersion(command, projectRoot);
    final version = resolvedVersion ??
        await getSdkVersion(command, workingDir: projectRoot);
    return _versionSupportsWidgetPreview(version);
  }

  Future<String?> _resolvedVersion(
      List<String> command, String projectRoot) async {
    try {
      final resolution = await context.sdks.resolve(LumideSdkResolveRequest(
        kind: LumideSdkKind.flutter,
        providerId: 'flutter',
        workspacePath: projectRoot,
        executable: 'flutter',
      ));
      if (resolution == null) return null;
      final selectedCommand = [resolution.executable, ...resolution.arguments];
      if (selectedCommand.join('\u0000') != command.join('\u0000')) return null;
      final version = resolution.installation.version;
      return _parseFlutterVersion(version) == null ? null : version;
    } catch (_) {
      return null;
    }
  }

  bool _versionSupportsWidgetPreview(String version) {
    final parsed = _parseFlutterVersion(version);
    if (parsed == null) return false;
    final (major, minor) = parsed;
    return major > 3 || (major == 3 && minor >= 47);
  }

  (int, int)? _parseFlutterVersion(String version) {
    final parts = RegExp(r'^(\d+)\.(\d+)(?:\.|$)').firstMatch(version);
    final major = int.tryParse(parts?.group(1) ?? '');
    final minor = int.tryParse(parts?.group(2) ?? '');
    if (major == null || minor == null) return null;
    return (major, minor);
  }

  void clearCache() => _widgetPreviewSupport.clear();

  Future<ProcessResult> runFlutter(
    String projectRoot,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    try {
      return await context.sdks.run(
        LumideSdkResolveRequest(
          kind: LumideSdkKind.flutter,
          providerId: 'flutter',
          workspacePath: projectRoot,
          executable: 'flutter',
          purpose: LumideSdkPurpose.run,
        ),
        arguments,
        workingDirectory: workingDirectory ?? projectRoot,
      );
    } catch (_) {
      final command = await _legacyFlutterCommand(projectRoot);
      return context.shell.run(
        command.first,
        [...command.skip(1), ...arguments],
        workingDirectory: workingDirectory ?? projectRoot,
      );
    }
  }

  Future<String> getSdkVersion(
    List<String> command, {
    String? workingDir,
  }) async {
    Process? process;
    StreamSubscription<String>? stdoutSubscription;
    StreamSubscription<List<int>>? stderrSubscription;
    try {
      process = await Process.start(
        command.first,
        [...command.skip(1), '--version'],
        workingDirectory: workingDir,
        runInShell: Platform.isWindows,
      );
      final output = StringBuffer();
      stdoutSubscription =
          process.stdout.transform(utf8.decoder).listen((chunk) {
        if (output.length < 4096) {
          output.write(chunk.substring(
              0, (4096 - output.length).clamp(0, chunk.length)));
        }
      });
      stderrSubscription = process.stderr.listen((_) {});
      final stdoutDone = stdoutSubscription.asFuture<void>();
      final stderrDone = stderrSubscription.asFuture<void>();
      final exitCode = await process.exitCode.timeout(versionCheckTimeout);
      await Future.wait([stdoutDone, stderrDone]).timeout(versionCheckTimeout);
      if (exitCode != 0) return 'Unknown';
      final words = output.toString().split(RegExp(r'\s+'));
      if (words.length > 1 && words.first == 'Flutter') return words[1];
    } on TimeoutException {
      process?.kill();
      try {
        await process?.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process?.kill(ProcessSignal.sigkill);
      }
    } catch (_) {
      return 'Unknown';
    } finally {
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
    }
    return 'Unknown';
  }
}
