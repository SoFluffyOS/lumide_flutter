import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

class SdkManager {
  SdkManager(this.context);

  final LumideContext context;

  Future<String?> _workspaceRoot() async {
    try {
      final root = await context.workspace.getRootUri();
      if (root case final uri? when uri.isNotEmpty) {
        return path.normalize(path.absolute(uri));
      }
    } catch (_) {}
    return null;
  }

  Future<List<String>> getFlutterCommand(String projectRoot) async {
    try {
      final resolution = await context.sdks.resolve(
        LumideSdkResolveRequest(
          kind: LumideSdkKind.flutter,
          providerId: 'flutter',
          workspacePath: projectRoot,
          executable: 'flutter',
        ),
      );
      if (resolution case final res? when res.executable.isNotEmpty) {
        final isWorkspaceScoped =
            res.installation.managerScope == LumideSdkManagerScope.workspace;
        final wsRoot = await _workspaceRoot();
        final normalizedProject = path.normalize(path.absolute(projectRoot));
        final isAtWorkspaceRoot = switch (wsRoot) {
          final root? => path.equals(root, normalizedProject),
          _ => true,
        };

        if (isWorkspaceScoped || isAtWorkspaceRoot) {
          return [res.executable, ...res.arguments];
        }

        if (wsRoot case final root?) {
          final wsResolution = await context.sdks.resolve(
            LumideSdkResolveRequest(
              kind: LumideSdkKind.flutter,
              providerId: 'flutter',
              workspacePath: root,
              executable: 'flutter',
            ),
          );
          if (wsResolution case final wsRes? when wsRes.executable.isNotEmpty) {
            final isWsScoped = wsRes.installation.managerScope ==
                LumideSdkManagerScope.workspace;
            if (isWsScoped) {
              return [wsRes.executable, ...wsRes.arguments];
            }
          }
        }

        return [res.executable, ...res.arguments];
      }
      throw StateError('No Flutter SDK is available for $projectRoot');
    } on UnsupportedError {
      // Older hosts do not expose the SDK API. Continue with legacy discovery.
    }
    return _legacyFlutterCommand(projectRoot);
  }

  Future<List<String>> _legacyFlutterCommand(String projectRoot) async {
    final searchDirs = <String>[projectRoot];
    final wsRoot = await _workspaceRoot();
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

  void clearCache() {}

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
    } on UnsupportedError {
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
    try {
      final result = await Process.run(
        command.first,
        [...command.skip(1), '--version'],
        workingDirectory: workingDir,
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return 'Unknown';
      final words = result.stdout.toString().split(RegExp(r'\s+'));
      if (words.length > 1 && words.first == 'Flutter') return words[1];
    } catch (_) {
      return 'Unknown';
    }
    return 'Unknown';
  }
}
