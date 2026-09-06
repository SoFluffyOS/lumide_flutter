import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

class SdkManager {
  SdkManager(this.context);

  final LumideContext context;

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
      if (resolution != null && resolution.executable.isNotEmpty) {
        return [resolution.executable, ...resolution.arguments];
      }
      throw StateError('No Flutter SDK is available for $projectRoot');
    } on UnsupportedError {
      // Older hosts do not expose the SDK API. Continue with legacy discovery.
    }
    return _legacyFlutterCommand(projectRoot);
  }

  Future<List<String>> _legacyFlutterCommand(String projectRoot) async {
    final fvmConfig = path.join(projectRoot, '.fvm', 'fvm_config.json');
    final fvmrc = path.join(projectRoot, '.fvmrc');
    if (await context.fs.exists(fvmConfig) || await context.fs.exists(fvmrc)) {
      final resolved = await _resolveViaShell('fvm');
      if (resolved != null) return [resolved, 'flutter'];
    }

    final puroJson = path.join(projectRoot, '.puro.json');
    if (await context.fs.exists(puroJson)) {
      final resolved = await _resolveViaShell('puro');
      if (resolved != null) return [resolved, 'flutter'];
    }

    final resolved = await _resolveViaShell('flutter');
    return [resolved ?? 'flutter'];
  }

  Future<String?> _resolveViaShell(String command) async {
    try {
      final resolver = Platform.isWindows ? 'where' : 'which';
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
        if (lower.endsWith('.exe') ||
            lower.endsWith('.bat') ||
            lower.endsWith('.cmd')) {
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
