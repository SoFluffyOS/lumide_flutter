import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

class SdkManager {
  final LumideContext context;

  SdkManager(this.context);

  List<String>? _resolvedFlutterCommand;

  /// Determines the command to use for Flutter based on the project root.
  ///
  /// Detects FVM / Puro based on workspace config files, then resolves
  /// the executable to an absolute path via the host's mediated shell
  /// (which uses `resolveExecutable` with proper Windows `.bat`/`.cmd`
  /// support and `PlatformUtils.environment`).
  Future<List<String>> getFlutterCommand(String projectRoot) async {
    if (_resolvedFlutterCommand != null) {
      return _resolvedFlutterCommand!;
    }

    // Check for FVM
    final fvmConfig = path.join(projectRoot, '.fvm', 'fvm_config.json');
    final fvmrc = path.join(projectRoot, '.fvmrc');
    if (await context.fs.exists(fvmConfig) || await context.fs.exists(fvmrc)) {
      final resolved = await _resolveViaShell('fvm');
      if (resolved != null) {
        _resolvedFlutterCommand = [resolved, 'flutter'];
        return _resolvedFlutterCommand!;
      }
    }

    // Check for Puro
    final puroJson = path.join(projectRoot, '.puro.json');
    if (await context.fs.exists(puroJson)) {
      final resolved = await _resolveViaShell('puro');
      if (resolved != null) {
        _resolvedFlutterCommand = [resolved, 'flutter'];
        return _resolvedFlutterCommand!;
      }
    }

    // Default: resolve 'flutter' from PATH via the host
    final resolved = await _resolveViaShell('flutter');
    if (resolved != null) {
      _resolvedFlutterCommand = [resolved];
      return _resolvedFlutterCommand!;
    }

    // Last resort: bare 'flutter' and let the OS figure it out
    _resolvedFlutterCommand = ['flutter'];
    return _resolvedFlutterCommand!;
  }

  /// Resolves a command name to its absolute path by running `which`/`where`
  /// through the host's mediated shell (which uses `resolveExecutable` with
  /// proper Windows PATH and extension handling).
  Future<String?> _resolveViaShell(String command) async {
    try {
      final whichCmd = Platform.isWindows ? 'where' : 'which';
      final result = await context.shell.run(whichCmd, [command]);
      if (result.exitCode == 0) {
        final resolved = result.stdout.toString().trim().split('\n').first;
        if (resolved.isNotEmpty) return resolved;
      }
    } catch (_) {}
    return null;
  }

  /// Clears the cached resolved path (e.g. after settings change).
  void clearCache() {
    _resolvedFlutterCommand = null;
  }

  Future<String> getSdkVersion(
    List<String> command, {
    String? workingDir,
  }) async {
    try {
      final result = await context.shell
          .run(command.first, [...command.sublist(1), '--version']);
      if (result.exitCode == 0) {
        // Output format: Flutter 3.19.0 • channel stable • ...
        final output = result.stdout.toString().split('\n').first;
        final version = output.split(' ')[1];
        return version;
      }
    } catch (e) {
      // ignore
    }
    return 'Unknown';
  }
}
