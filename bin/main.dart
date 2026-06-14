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
    targetService = TargetService(context, projectService);
    runService = RunService(context, projectService, sdkManager, deviceService,
        targetService, daemonService);
    deviceService.onDidChange = runService.refreshLaunchConfigurations;
    targetService.onDidChange = runService.refreshLaunchConfigurations;

    // Inject RunService into FlutterService (break circular dependency)
    flutterService.setRunService(runService);

    // 2. Setup UI & Listeners
    await daemonService.start();
    await statusBarService.init();
    await deviceService.init();
    await targetService.init();
    await runService.init();

    // 3. Environment Check
    final hasSdk = await flutterService.checkSdk();
    if (!hasSdk) {
      await context.window.showMessage(
          'Flutter SDK not found. Make sure "flutter" is in your PATH.',
          type: MessageType.error);
      await statusBarService.updateVersion('Not Found');
      return;
    }

    // 4. Register Commands
    _registerCommands(context);

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

  void _registerCommands(LumideContext context) {
    context.commands.registerCommand(
      id: cmdFlutterDoctor,
      title: 'Flutter: Doctor',
      callback: ([args]) => flutterService.doctor(),
    );

    context.commands.registerCommand(
      id: cmdFlutterPubGet,
      title: 'Flutter: Pub Get',
      callback: ([args]) => flutterService.pubGet(),
    );

    context.commands.registerCommand(
      id: cmdFlutterClean,
      title: 'Flutter: Clean',
      callback: ([args]) => flutterService.clean(),
    );

    context.commands.registerCommand(
      id: cmdFlutterCreate,
      title: 'Flutter: New Project',
      callback: ([args]) => flutterService.create(),
    );

    context.commands.registerCommand(
      id: cmdFlutterSelectDevice,
      title: 'Flutter: Select Device',
      callback: ([args]) => deviceService.selectDevice(),
    );

    context.commands.registerCommand(
      id: cmdFlutterSelectTarget,
      title: 'Flutter: Select Target',
      callback: ([args]) => targetService.selectTarget(),
    );

    context.commands.registerCommand(
      id: cmdFlutterSetFlavor,
      title: 'Flutter: Set Flavor',
      callback: ([args]) => runService.setFlavor(),
    );

    context.commands.registerCommand(
      id: cmdFlutterSetBuildMode,
      title: 'Flutter: Set Build Mode',
      callback: ([args]) => runService.setBuildMode(),
    );

    context.commands.registerCommand(
      id: cmdFlutterRun,
      title: 'Flutter: Run',
      callback: ([args]) => runService.run(),
    );

    context.commands.registerCommand(
      id: cmdFlutterDebug,
      title: 'Flutter: Debug',
      callback: ([args]) => runService.debug(),
    );

    context.commands.registerCommand(
      id: cmdFlutterAttach,
      title: 'Flutter: Attach',
      callback: ([args]) => runService.attach(),
    );

    context.commands.registerCommand(
      id: cmdFlutterHotReload,
      title: 'Flutter: Hot Reload',
      callback: ([args]) => runService.hotReload(),
    );

    context.commands.registerCommand(
      id: cmdFlutterHotRestart,
      title: 'Flutter: Hot Restart',
      callback: ([args]) => runService.hotRestart(),
    );

    context.commands.registerCommand(
      id: cmdFlutterStop,
      title: 'Flutter: Stop App',
      callback: ([args]) => runService.stop(),
    );

    context.commands.registerCommand(
      id: cmdFlutterOpenDevToolsWebview,
      title: 'Flutter: Open DevTools',
      callback: ([args]) => runService.openDevToolsInWebview(),
    );

    context.commands.registerCommand(
      id: cmdFlutterOpenDevTools,
      title: 'Flutter: Open DevTools (Browser)',
      callback: ([args]) => runService.openDevTools(),
    );

    context.commands.registerCommand(
      id: cmdFlutterTools,
      title: 'Flutter: Tools Menu',
      callback: ([args]) => flutterService.showToolsMenu(args),
    );
  }

  @override
  Future<void> onDeactivate() async {
    await daemonService.dispose();
    await runService.dispose();
    await deviceService.dispose();
    await targetService.dispose();
    await statusBarService.dispose();
    await flutterService.dispose();
  }
}
