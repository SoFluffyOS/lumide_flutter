import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/lumide_flutter.dart';
import 'package:lumide_flutter/src/constants.dart';

void main() => FlutterPlugin().run();

class FlutterPlugin extends LumidePlugin {
  late LogService logService;
  late FlutterService flutterService;
  late DeviceService deviceService;
  late StatusBarService statusBarService;
  late ProjectService projectService;
  late SdkManager sdkManager;
  late DaemonService daemonService;
  late LaunchConfigService launchConfigService;
  late TargetService targetService;
  late RunService runService;

  @override
  Future<void> onActivate(LumideContext context) async {
    // 1. Initialize core services
    logService = LogService(log);
    statusBarService = StatusBarService(context);
    projectService = ProjectService(context);
    sdkManager = SdkManager(context);
    daemonService =
        DaemonService(context, projectService, sdkManager, logService);
    flutterService = FlutterService(context, projectService, sdkManager);
    deviceService = DeviceService(context, statusBarService, daemonService);
    launchConfigService = LaunchConfigService(context, projectService, log);
    targetService = TargetService(context, projectService, launchConfigService);
    runService = RunService(context, projectService, sdkManager, deviceService,
        targetService, daemonService, launchConfigService);
    deviceService.onDidChange = runService.refreshLaunchConfigurations;
    targetService.onDidChange = runService.refreshLaunchConfigurations;

    // Inject RunService into FlutterService (break circular dependency)
    flutterService.setRunService(runService);

    // 2. Setup UI & Listeners
    unawaited(daemonService.start());
    await runService
        .init(); // Register provider first so updateConfigurations notifications work
    await Future.wait([
      statusBarService.init(),
      deviceService.init(),
      launchConfigService.init(),
      targetService.init(),
    ]);
    launchConfigService.onDidChange = runService.refreshLaunchConfigurations;

    // 3. Environment Check (asynchronous in background)
    unawaited(flutterService.checkSdk().then((hasSdk) async {
      if (!hasSdk) {
        await context.window.showMessage(
            'Flutter SDK not found. Make sure "flutter" is in your PATH.',
            type: MessageType.error);
        await statusBarService.updateVersion('Not Found');
      }
    }));

    // 4. Register Commands & Menu Actions
    await _registerCommands(context);
    await _registerMenuActions(context);

    // 5. Register Toolbar Listener
    context.toolbar.onTap((id, position) {
      switch (id) {
        case cmdFlutterTarget:
        case cmdFlutterSelectTarget:
          targetService.selectTarget(position);
          break;
        case cmdFlutterDevice:
          deviceService.selectDevice(position);
          break;
        case cmdFlutterSetFlavor:
          runService.setFlavor();
          break;
        case cmdFlutterSetBuildMode:
          runService.setBuildMode();
          break;
        case cmdFlutterRun:
          runService.run();
          break;
        case cmdFlutterDebug:
          runService.debug();
          break;
        case cmdFlutterAttach:
          runService.attach();
          break;
        case cmdFlutterStop:
          runService.stop();
          break;
        case cmdFlutterHotReload:
          runService.hotReload();
          break;
        case cmdFlutterHotRestart:
          runService.hotRestart();
          break;
      }
    });

    // 6. Initial Data Fetch
    unawaited(deviceService.refreshDevices());

    await context.window.showMessage('Flutter plugin ready');
  }

  Future<void> _registerCommands(LumideContext context) async {
    await Future.wait([
      context.commands.registerCommand(
        id: cmdFlutterDoctor,
        title: 'Flutter: Doctor',
        callback: ([args]) => flutterService.doctor(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterPubGet,
        title: 'Flutter: Pub Get',
        callback: ([args]) => flutterService.pubGet(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterClean,
        title: 'Flutter: Clean',
        callback: ([args]) => flutterService.clean(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterCreate,
        title: 'Flutter: New Project',
        callback: ([args]) => flutterService.create(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterSelectDevice,
        title: 'Flutter: Select Device',
        callback: ([args]) => deviceService.selectDevice(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterSelectTarget,
        title: 'Flutter: Select Target',
        callback: ([args]) => targetService.selectTarget(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterSetFlavor,
        title: 'Flutter: Set Flavor',
        callback: ([args]) => runService.setFlavor(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterSetBuildMode,
        title: 'Flutter: Set Build Mode',
        callback: ([args]) => runService.setBuildMode(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterRun,
        title: 'Flutter: Run',
        callback: ([args]) => runService.run(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterDebug,
        title: 'Flutter: Debug',
        callback: ([args]) => runService.debug(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterAttach,
        title: 'Flutter: Attach',
        callback: ([args]) => runService.attach(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterHotReload,
        title: 'Flutter: Hot Reload',
        callback: ([args]) => runService.hotReload(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterHotRestart,
        title: 'Flutter: Hot Restart',
        callback: ([args]) => runService.hotRestart(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterStop,
        title: 'Flutter: Stop App',
        callback: ([args]) => runService.stop(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterOpenDevToolsWebview,
        title: 'Flutter: Open DevTools',
        callback: ([args]) => runService.openDevToolsInWebview(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterOpenDevTools,
        title: 'Flutter: Open DevTools (Browser)',
        callback: ([args]) => runService.openDevTools(),
      ),
      context.commands.registerCommand(
        id: cmdFlutterTools,
        title: 'Flutter: Tools Menu',
        callback: ([args]) => flutterService.showToolsMenu(args),
      ),
      context.commands.registerCommand(
        id: cmdFlutterPubGetForContext,
        title: 'Flutter: Pub Get Here',
        callback: ([args]) => flutterService.pubGetForContext(args),
      ),
      context.commands.registerCommand(
        id: cmdFlutterCleanForContext,
        title: 'Flutter: Clean Here',
        callback: ([args]) => flutterService.cleanForContext(args),
      ),
      context.commands.registerCommand(
        id: cmdFlutterSetTargetForContext,
        title: 'Flutter: Set as Target',
        callback: ([args]) => targetService.setTargetFromContext(args),
      ),
      context.commands.registerCommand(
        id: cmdFlutterCreateForContext,
        title: 'Flutter: New Project Here',
        callback: ([args]) => flutterService.createForContext(args),
      ),
      context.commands.registerCommand(
        id: cmdFlutterNewDartFileForContext,
        title: 'Flutter: New Dart File',
        callback: ([args]) => flutterService.newDartFileForContext(args),
      ),
    ]);
  }

  Future<void> _registerMenuActions(LumideContext context) async {
    await Future.wait([
      context.menus.registerAction(
        const LumideMenuAction(
          id: 'new_dart_file_tree',
          title: 'New Dart File',
          command: cmdFlutterNewDartFileForContext,
          location: LumideMenuLocation.fileTreeItem,
          group: 'create',
          priority: 140,
        ),
      ),
      context.menus.registerAction(
        const LumideMenuAction(
          id: 'create_file_tree',
          title: 'Create Flutter Project Here',
          command: cmdFlutterCreateForContext,
          location: LumideMenuLocation.fileTreeItem,
          group: 'create',
          priority: 130,
        ),
      ),
      context.menus.registerAction(
        const LumideMenuAction(
          id: 'pub_get_file_tree',
          title: 'Flutter Pub Get',
          command: cmdFlutterPubGetForContext,
          location: LumideMenuLocation.fileTreeItem,
          group: 'tools',
          priority: 110,
        ),
      ),
      context.menus.registerAction(
        const LumideMenuAction(
          id: 'clean_file_tree',
          title: 'Flutter Clean',
          command: cmdFlutterCleanForContext,
          location: LumideMenuLocation.fileTreeItem,
          group: 'tools',
          priority: 100,
        ),
      ),
      context.menus.registerAction(
        const LumideMenuAction(
          id: 'set_target_file_tree',
          title: 'Set as Flutter Target',
          command: cmdFlutterSetTargetForContext,
          location: LumideMenuLocation.fileTreeItem,
          group: 'target',
          priority: 120,
        ),
      ),
    ]);
  }

  @override
  Future<void> onDeactivate() async {
    await daemonService.dispose();
    await runService.dispose();
    await deviceService.dispose();
    await targetService.dispose();
    await launchConfigService.dispose();
    await statusBarService.dispose();
    await flutterService.dispose();
  }
}
