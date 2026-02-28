import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/run_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:path/path.dart' as path;

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

    return await _runWithCwd(cmd, args, root);
  }

  Future<void> _runCommandInProject(List<String> args, String statusMsg) async {
    try {
      final root = await projectService.getProjectRoot();
      final cmd = await sdkManager.getFlutterCommand(root);
      await _runCommand(cmd, args, statusMsg, workingDir: root);
    } catch (e) {
      await context.window.showMessage(e.toString(), type: MessageType.error);
    }
  }

  Future<void> _runCommand(
      List<String> cmdParts, List<String> args, String statusMsg,
      {String? workingDir}) async {
    await context.window.showMessage(statusMsg);

    final output = runService.channel;
    await output?.clear();
    await output?.show();
    await output?.append('> ${cmdParts.join(' ')} ${args.join(' ')}\n');

    try {
      final result = await _runWithCwd(cmdParts, args, workingDir);

      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (stdout.isNotEmpty) {
        await output?.append('$stdout\n');
      }
      if (stderr.isNotEmpty) {
        await output?.append('$stderr\n');
      }

      if (result.exitCode == 0) {
        await context.window
            .showMessage('${args.join(' ')} completed successfully');
      } else {
        await context.window.showMessage(
            '${args.join(' ')} failed with exit code ${result.exitCode}',
            type: MessageType.error);
      }
    } catch (e) {
      await output?.append('[ERROR] $e\n');
      await context.window
          .showMessage('Command failed: $e', type: MessageType.error);
    }
  }

  Future<ProcessResult> _runWithCwd(
      List<String> cmdParts, List<String> args, String? workingDir) async {
    final fullArgs = [...cmdParts.sublist(1), ...args];
    final executable = cmdParts.first;

    return await context.shell
        .run(executable, fullArgs, workingDirectory: workingDir);
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

    final validProjects = <String>[];
    for (final project in projects) {
      if (project.contains('.dart_tool')) continue;
      try {
        final pubspecString =
            await context.fs.readString(path.join(project, 'pubspec.yaml'));
        if (RegExp(r'resolution:\s*workspace').hasMatch(pubspecString)) {
          continue;
        }
        validProjects.add(project);
      } catch (_) {
        // Keep in list to show read error later
        validProjects.add(project);
      }
    }

    if (validProjects.isEmpty) {
      await context.window.showMessage(
          'No runnable Flutter projects found in this workspace.',
          type: MessageType.info);
      return;
    }

    await context.window
        .showMessage('Running pub get in ${validProjects.length} projects');

    final output = runService.channel;
    await output?.clear();
    await output?.show();
    await output?.append(
        '> Running pub get in ${validProjects.length} projects...\n\n');

    int successCount = 0;
    int failCount = 0;

    final workspaceRootUri = await context.workspace.getRootUri();

    for (final project in validProjects) {
      try {
        final cmd = await sdkManager.getFlutterCommand(project);

        String displayPath;
        if (workspaceRootUri != null &&
            path.isWithin(workspaceRootUri, project)) {
          displayPath = path.relative(project, from: workspaceRootUri);
        } else {
          displayPath = path.basename(project);
        }

        await output?.append('--- [ $displayPath ] ---\n');

        final result = await _runWithCwd(cmd, ['pub', 'get'], project);

        final stdout = result.stdout.toString().trim();
        final stderr = result.stderr.toString().trim();

        if (stdout.isNotEmpty) await output?.append('$stdout\n');
        if (stderr.isNotEmpty) await output?.append('$stderr\n');

        if (result.exitCode != 0) {
          io.stderr.writeln('Failed pub get in $project: ${result.stderr}');
          failCount++;
        } else {
          successCount++;
        }
        await output?.append('\n');
      } catch (e) {
        io.stderr.writeln('Exception in $project: $e');
        await output?.append('Exception fetching project: $e\n\n');
        failCount++;
      }
    }

    if (failCount == 0) {
      await context.window.showMessage(
        'Pub get completed in all $successCount projects',
        type: MessageType.info,
      );
      await output?.append('> Pub get completed successfully.\n');
    } else {
      await context.window.showMessage(
        'Pub get failed in $failCount projects.',
        type: MessageType.error,
      );
      await output?.append('> Pub get finished with $failCount errors.\n');
    }
  }

  Future<void> dispose() async {
    // Clean up if needed
  }
}
