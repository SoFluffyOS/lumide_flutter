import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/lumide_flutter.dart';
import 'package:lumide_flutter/src/constants.dart';

void main() => FlutterPlugin().run();

class FlutterPlugin extends LumidePlugin {
  late FlutterService flutterService;
  late DeviceService deviceService;
  late StatusBarService statusBarService;
  late ProjectService projectService;
  late SdkManager sdkManager;
  late RunService runService;

  @override
  Future<void> onActivate(LumideContext context) async {
    // 1. Initialize core services
    statusBarService = StatusBarService(context);
    projectService = ProjectService(context);
    sdkManager = SdkManager(context);
    flutterService = FlutterService(context, projectService, sdkManager);
    deviceService = DeviceService(context, statusBarService, sdkManager);
    runService = RunService(context, projectService, sdkManager, deviceService);

    // Inject RunService into FlutterService (break circular dependency)
    flutterService.setRunService(runService);

    // 2. Setup UI & Listeners
    await statusBarService.init();
    await runService.init();

    // 3. Environment Check
    final hasSdk = await flutterService.checkSdk();
    if (!hasSdk) {
      await context.window.showMessage('Flutter SDK not found in PATH.',
          type: MessageType.error);
      await statusBarService.updateVersion('Not Found');
      return;
    }

    // 4. Register Commands
    _registerCommands(context);

    // 5. Register Toolbar Listener
    context.toolbar.onTap((id, position) {
      switch (id) {
        case cmdFlutterDevice:
          deviceService.selectDevice(position);
          break;
        case cmdFlutterRun:
          runService.run();
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
    await deviceService.refreshDevices();

    await context.window.showMessage('Flutter plugin activated!');
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
      id: cmdFlutterRun,
      title: 'Flutter: Run',
      callback: ([args]) => runService.run(),
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
    await runService.dispose();
    await deviceService.dispose();
    await statusBarService.dispose();
    await flutterService.dispose();
    await sdkManager.dispose();
    await projectService.dispose();
  }
}
