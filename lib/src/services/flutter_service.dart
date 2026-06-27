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
      final root = await projectService.getProjectRoot();
      final cmd = await sdkManager.getFlutterCommand(root);
      final result =
          await context.shell.run(cmd.first, [...cmd.sublist(1), '--version']);
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

  Future<void> pubGetForContext(Map<String, dynamic>? args) async {
    await _runCommandForContext(
      args,
      ['pub', 'get'],
      'Running Pub Get...',
    );
  }

  Future<void> clean() async {
    await _runCommandInProject(['clean'], 'Cleaning build...');
  }

  Future<void> cleanForContext(Map<String, dynamic>? args) async {
    await _runCommandForContext(
      args,
      ['clean'],
      'Cleaning build...',
    );
  }

  Future<void> create() async {
    try {
      final workspaceRoot = await projectService.getWorkspaceRoot();
      await _createInDirectory(workspaceRoot);
    } catch (e) {
      await context.window.showMessage(e.toString(), type: MessageType.error);
    }
  }

  Future<void> createForContext(Map<String, dynamic>? args) async {
    try {
      final targetDirectory = projectService.folderFromMenuContext(args) ??
          await projectService.getWorkspaceRoot();
      await _createInDirectory(targetDirectory);
    } catch (e) {
      await context.window.showMessage(e.toString(), type: MessageType.error);
    }
  }

  Future<void> newDartFileForContext(Map<String, dynamic>? args) async {
    try {
      final targetDirectory = projectService.folderFromMenuContext(args) ??
          await projectService.getWorkspaceRoot();
      final relativePath = await _askDartFilePath();
      if (relativePath == null) return;

      final filePath = await _resolveWorkspaceFilePath(
        targetDirectory,
        relativePath,
      );
      if (await context.fs.exists(filePath)) {
        await context.window.showMessage(
          '${path.basename(filePath)} already exists.',
          type: MessageType.error,
        );
        return;
      }

      final parentDirectory = path.dirname(filePath);
      if (!await context.fs.exists(parentDirectory)) {
        await context.fs.createDirectory(parentDirectory, recursive: true);
      }
      await context.fs.writeString(filePath, '');
      await context.editor.openDocument(Uri.file(filePath).toString());
    } catch (e) {
      await context.window.showMessage(e.toString(), type: MessageType.error);
    }
  }

  Future<String?> _askDartFilePath() async {
    final rawPath = await context.window.showInputBox(
      prompt: 'Dart file path',
      placeHolder: 'models/user',
    );
    if (rawPath == null) return null;

    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return null;
    if (path.isAbsolute(trimmed)) {
      await context.window.showMessage(
        'Enter a relative path inside the selected folder.',
        type: MessageType.error,
      );
      return null;
    }

    final parts = path.split(trimmed.replaceAll('\\', '/'));
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      await context.window.showMessage(
        'Path cannot contain empty, current, or parent directory segments.',
        type: MessageType.error,
      );
      return null;
    }

    final filePath = trimmed.endsWith('.dart') ? trimmed : '$trimmed.dart';
    final baseName = path.basenameWithoutExtension(filePath);
    if (!_isValidDartFileBaseName(baseName)) {
      await context.window.showMessage(
        'Dart file name should use lower_snake_case, like my_widget.dart.',
        type: MessageType.error,
      );
      return null;
    }
    return path.joinAll(path.split(filePath.replaceAll('\\', '/')));
  }

  Future<String> _resolveWorkspaceFilePath(
    String targetDirectory,
    String relativePath,
  ) async {
    final workspaceRoot =
        path.normalize(await projectService.getWorkspaceRoot());
    final normalizedTarget = path.normalize(targetDirectory);
    if (normalizedTarget != workspaceRoot &&
        !path.isWithin(workspaceRoot, normalizedTarget)) {
      throw Exception('Selected folder is outside the workspace.');
    }

    final filePath = path.normalize(path.join(normalizedTarget, relativePath));
    if (filePath != workspaceRoot && !path.isWithin(workspaceRoot, filePath)) {
      throw Exception('File path must stay inside the workspace.');
    }
    if (filePath != normalizedTarget &&
        !path.isWithin(normalizedTarget, filePath)) {
      throw Exception('File path must stay inside the selected folder.');
    }
    return filePath;
  }

  Future<void> _createInDirectory(String workingDirectory) async {
    final projectName = await _askProjectName();
    if (projectName == null) return;

    final template = await _askCreateTemplate();
    if (template == null) return;

    final args = <String>['create'];
    args.addAll(template.args);

    if (template.supportsPlatforms) {
      final platformArgs = await _askPlatformArgs();
      if (platformArgs == null) return;
      args.addAll(platformArgs);
    }

    if (template.usesOrg) {
      final org = await _askOrganization();
      if (org == null) return;
      if (org.isNotEmpty) {
        args.addAll(['--org', org]);
      }
    }

    final pubArgs = await _askPubArgs();
    if (pubArgs == null) return;
    args.addAll(pubArgs);
    args.add(projectName);

    final cmd = await sdkManager.getFlutterCommand(workingDirectory);
    await _runCommand(
      cmd,
      args,
      'Creating project $projectName...',
      workingDir: workingDirectory,
    );
    projectService.clearCaches();
  }

  Future<String?> _askProjectName() async {
    final projectName =
        await context.window.showInputBox(prompt: 'Enter project name');
    if (projectName == null) return null;

    final normalized = projectName.trim();
    if (normalized.isEmpty) return null;
    if (!_isValidDartPackageName(normalized)) {
      await context.window.showMessage(
        'Project name must be a valid Dart package name, like my_app.',
        type: MessageType.error,
      );
      return null;
    }
    return normalized;
  }

  Future<_CreateTemplate?> _askCreateTemplate() async {
    final selected = await context.window.showQuickPick(
      const [
        QuickPickItem(
          label: 'App',
          description: 'Default Flutter application',
          payload: 'app',
          icon: iconCode,
        ),
        QuickPickItem(
          label: 'Empty App',
          description: 'Minimal Flutter application',
          payload: 'empty',
          icon: iconCode,
        ),
        QuickPickItem(
          label: 'Package',
          description: 'Shareable Dart/Flutter package',
          payload: 'package',
          icon: iconArchive,
        ),
        QuickPickItem(
          label: 'Plugin',
          description: 'Flutter plugin with platform code',
          payload: 'plugin',
          icon: iconZap,
        ),
        QuickPickItem(
          label: 'Module',
          description: 'Flutter module for an existing app',
          payload: 'module',
          icon: iconLayout,
        ),
      ],
      placeholder: 'Select Flutter project template',
    );
    if (selected == null) return null;

    return switch (selected.payload as String) {
      'empty' => const _CreateTemplate(
          args: ['--empty'],
          supportsPlatforms: true,
          usesOrg: true,
        ),
      'package' => const _CreateTemplate(
          args: ['--template', 'package'],
          supportsPlatforms: false,
          usesOrg: false,
        ),
      'plugin' => const _CreateTemplate(
          args: ['--template', 'plugin'],
          supportsPlatforms: true,
          usesOrg: true,
        ),
      'module' => const _CreateTemplate(
          args: ['--template', 'module'],
          supportsPlatforms: false,
          usesOrg: true,
        ),
      _ => const _CreateTemplate(
          args: [],
          supportsPlatforms: true,
          usesOrg: true,
        ),
    };
  }

  Future<List<String>?> _askPlatformArgs() async {
    final selected = await context.window.showQuickPick(
      const [
        QuickPickItem(
          label: 'All Platforms',
          description: 'Flutter default',
          payload: '',
          icon: iconGlobe,
        ),
        QuickPickItem(
          label: 'Mobile',
          description: 'Android, iOS',
          payload: 'android,ios',
          icon: iconSmartphone,
        ),
        QuickPickItem(
          label: 'Web',
          description: 'Web only',
          payload: 'web',
          icon: iconGlobe,
        ),
        QuickPickItem(
          label: 'Desktop',
          description: 'macOS, Windows, Linux',
          payload: 'macos,windows,linux',
          icon: iconMonitor,
        ),
      ],
      placeholder: 'Select target platforms',
    );
    if (selected == null) return null;

    final platforms = selected.payload as String;
    if (platforms.isEmpty) return const [];
    return ['--platforms', platforms];
  }

  Future<String?> _askOrganization() async {
    final org = await context.window.showInputBox(
      prompt: 'Organization identifier',
      value: 'com.example',
    );
    if (org == null) return null;
    final normalized = org.trim();
    if (normalized.isEmpty) return '';
    if (!_isValidOrganization(normalized)) {
      await context.window.showMessage(
        'Organization must use reverse-domain notation, like com.example.',
        type: MessageType.error,
      );
      return null;
    }
    return normalized;
  }

  Future<List<String>?> _askPubArgs() async {
    final selected = await context.window.showQuickPick(
      const [
        QuickPickItem(
          label: 'Run Pub Get',
          description: 'Default',
          payload: '',
          icon: iconArchive,
        ),
        QuickPickItem(
          label: 'Skip Pub Get',
          description: 'Use --no-pub',
          payload: '--no-pub',
          icon: iconTerminal,
        ),
      ],
      placeholder: 'Run pub get after create?',
    );
    if (selected == null) return null;

    final flag = selected.payload as String;
    if (flag.isEmpty) return const [];
    return [flag];
  }

  bool _isValidDartPackageName(String value) {
    return RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value) && !value.endsWith('_');
  }

  bool _isValidOrganization(String value) {
    return RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
        .hasMatch(value);
  }

  bool _isValidDartFileBaseName(String value) {
    return RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value) && !value.endsWith('_');
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

  Future<void> _runCommandForContext(
    Map<String, dynamic>? args,
    List<String> toolArgs,
    String statusMsg,
  ) async {
    try {
      final root = await projectService.projectRootFromMenuContext(args) ??
          await projectService.getProjectRoot();
      final cmd = await sdkManager.getFlutterCommand(root);
      await _runCommand(cmd, toolArgs, statusMsg, workingDir: root);
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
    await output?.append(
      '> ${cmdParts.join(' ')} ${args.join(' ')}\n'
      'Working Directory: ${workingDir ?? io.Directory.current.path}\n',
    );

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
        description: 'flutter pub get',
        detail: 'flutter pub get',
        tooltip: 'Run flutter pub get in the current Flutter project.',
        payload: 'pubGet',
        icon: iconArchive,
      ),
    );

    items.add(
      const QuickPickItem(
        label: 'Clean',
        description: 'flutter clean',
        detail: 'flutter clean',
        tooltip: 'Run flutter clean in the current Flutter project.',
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
        tooltip:
            'Run flutter pub get in every Flutter project found in the workspace.',
        payload: 'pubGetAll',
        icon: iconArchive,
      ),
    );

    items.add(const QuickPickItem(label: '', isSeparator: true));

    items.add(
      const QuickPickItem(
        label: 'Doctor',
        description: 'flutter doctor',
        detail: 'flutter doctor',
        tooltip: 'Run flutter doctor and show diagnostic output.',
        payload: 'doctor',
        icon: iconZap,
      ),
    );

    if (runService.isRunning) {
      items.add(
        const QuickPickItem(
          label: 'Open DevTools',
          detail: 'Open in Lumide',
          tooltip: 'Open Dart DevTools in a Lumide webview panel.',
          payload: 'devtools-webview',
          icon: iconLayout,
        ),
      );
      items.add(
        const QuickPickItem(
          label: 'Open DevTools (Browser)',
          detail: 'Open externally',
          tooltip: 'Open Dart DevTools in the system browser.',
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
    final projects = await projectService.findAllProjects(forceRefresh: true);

    if (projects.isEmpty) {
      await context.window.showMessage(
          'No Flutter projects found in this workspace.',
          type: MessageType.warning);
      return;
    }

    final validProjects = <String>[];
    for (final project in projects) {
      if (path
          .split(project)
          .any((part) => part.startsWith('.') || part == 'build')) {
        continue;
      }
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
        await output?.append('Working Directory: $project\n');

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

class _CreateTemplate {
  const _CreateTemplate({
    required this.args,
    required this.supportsPlatforms,
    required this.usesOrg,
  });

  final List<String> args;
  final bool supportsPlatforms;
  final bool usesOrg;
}
