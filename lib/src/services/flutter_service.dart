import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/run_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';

class FlutterService {
  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;

  FlutterService(this.context, this.projectService, this.sdkManager);

  Future<bool> checkSdk() async {
    try {
      final result = await context.shell.run('flutter', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> doctor() async {
    await _runCommandInProject(['doctor'], 'Running Flutter Doctor...');
  }

  Future<void> pubGet() async {
    await _runCommandInProject(['pub', 'get'], 'Running Pub Get...');
  }

  Future<void> clean() async {
    await _runCommandInProject(['clean'], 'Cleaning build...');
  }

  Future<void> create() async {
    final projectName =
        await context.window.showInputBox(prompt: 'Enter project name');
    if (projectName != null && projectName.isNotEmpty) {
      await _runCommand(['flutter'], ['create', projectName],
          'Creating project $projectName...');
    }
  }

  Future<ProcessResult> run(List<String> args) async {
    final root = await projectService.getProjectRoot();
    final cmd = await sdkManager.getFlutterCommand(root);

    if (root != null) {
      return await _runWithCwd(cmd, args, root);
    }

    return await context.shell.run(cmd.first, [...cmd.sublist(1), ...args]);
  }

  Future<void> _runCommandInProject(List<String> args, String statusMsg) async {
    final root = await projectService.getProjectRoot();
    if (root == null) {
      await context.window.showMessage(
          'No Flutter project found. Open a folder with a pubspec.yaml.',
          type: MessageType.error);
      return;
    }

    final cmd = await sdkManager.getFlutterCommand(root);
    await _runCommand(cmd, args, statusMsg, workingDir: root);
  }

  Future<void> _runCommand(
      List<String> cmdParts, List<String> args, String statusMsg,
      {String? workingDir}) async {
    await context.window.showMessage(statusMsg);
    try {
      final result = await _runWithCwd(cmdParts, args, workingDir);

      io.stderr
          .writeln('Command: $cmdParts ${args.join(' ')} (in $workingDir)');
      io.stderr.writeln('Stdout: ${result.stdout}');
      io.stderr.writeln('Stderr: ${result.stderr}');

      if (result.exitCode == 0) {
        await context.window.showMessage('${args.first} completed');
      } else {
        await context.window.showMessage(
            '${args.first} failed (exit code ${result.exitCode}). Check Build Output.',
            type: MessageType.error);
      }
    } catch (e) {
      await context.window
          .showMessage('Command failed: $e', type: MessageType.error);
      io.stderr.writeln('Error: $e');
    }
  }

  Future<ProcessResult> _runWithCwd(
      List<String> cmdParts, List<String> args, String? workingDir) async {
    final fullArgs = [...cmdParts.sublist(1), ...args];
    final executable = cmdParts.first;

    if (workingDir != null) {
      final cmdStr = '$executable ${fullArgs.join(' ')}';
      return await context.shell
          .run('sh', ['-c', 'cd "$workingDir" && $cmdStr']);
    }

    return await context.shell.run(executable, fullArgs);
  }

  late final RunService runService;

  void setRunService(RunService service) {
    runService = service;
  }

  Future<void> showToolsMenu([Map<String, dynamic>? args]) async {
    final items = <QuickPickItem>[];

    items.add(
      const QuickPickItem(
        label: 'Pub Get',
        description: 'Current Project',
        detail: 'flutter pub get',
        payload: 'pubGet',
        icon: iconArchive,
      ),
    );

    items.add(
      const QuickPickItem(
        label: 'Clean',
        description: 'Current Project',
        detail: 'flutter clean',
        payload: 'clean',
        icon: iconTrash,
      ),
    );

    items.add(const QuickPickItem(label: '', isSeparator: true));

    items.add(
      const QuickPickItem(
        label: 'Pub Get All',
        description: 'Workspace',
        detail: 'Run in all found projects',
        payload: 'pubGetAll',
        icon: iconArchive,
      ),
    );

    items.add(const QuickPickItem(label: '', isSeparator: true));

    items.add(
      const QuickPickItem(
        label: 'Doctor',
        detail: 'flutter doctor',
        payload: 'doctor',
        icon: iconZap,
      ),
    );

    if (runService.isRunning) {
      items.add(
        const QuickPickItem(
          label: 'Open DevTools',
          detail: 'Open Dart DevTools in Webview pane',
          payload: 'devtools-webview',
          icon: iconLayout,
        ),
      );
      items.add(
        const QuickPickItem(
          label: 'Open DevTools (Browser)',
          detail: 'Open Dart DevTools in external browser',
          payload: 'devtools',
          icon: iconGlobe,
        ),
      );
    }

    Map<String, int>? position;
    if (args != null && args.containsKey('position')) {
      final posMap = args['position'] as Map;
      if (posMap['x'] is num && posMap['y'] is num) {
        position = {
          'x': (posMap['x'] as num).toInt(),
          'y': (posMap['y'] as num).toInt(),
        };
      }
    }

    final selected = await context.window.showQuickPick(
      items,
      placeholder: 'Select Flutter Tool',
      position: position,
    );

    if (selected != null) {
      final payload = selected.payload as String;
      switch (payload) {
        case 'pubGet':
          await pubGet();
          break;
        case 'clean':
          await clean();
          break;
        case 'pubGetAll':
          await pubGetAll();
          break;
        case 'doctor':
          await doctor();
          break;
        case 'devtools':
          await runService.openDevTools();
          break;
        case 'devtools-webview':
          await runService.openDevToolsInWebview();
          break;
      }
    }
  }

  Future<void> pubGetAll() async {
    await context.window.showMessage('Scanning workspace for Flutter projects');
    final projects = await projectService.findAllProjects();

    if (projects.isEmpty) {
      await context.window.showMessage(
          'No Flutter projects found in this workspace.',
          type: MessageType.warning);
      return;
    }

    await context.window
        .showMessage('Running pub get in ${projects.length} projects');

    final results = await Future.wait(projects.map((project) async {
      try {
        final cmd = await sdkManager.getFlutterCommand(project);
        final result = await _runWithCwd(cmd, ['pub', 'get'], project);
        if (result.exitCode != 0) {
          io.stderr.writeln('Failed pub get in $project: ${result.stderr}');
          return false;
        }
        return true;
      } catch (e) {
        io.stderr.writeln('Exception in $project: $e');
        return false;
      }
    }));

    final successCount = results.where((s) => s).length;
    final failCount = results.where((s) => !s).length;

    if (failCount == 0) {
      await context.window.showMessage(
        'Pub get completed in all $successCount projects',
        type: MessageType.info,
      );
    } else {
      await context.window.showMessage(
        'Pub get finished. $successCount succeeded, $failCount failed. Check logs.',
        type: MessageType.warning,
      );
    }
  }

  Future<void> dispose() async {
    // Clean up if needed
  }
}
