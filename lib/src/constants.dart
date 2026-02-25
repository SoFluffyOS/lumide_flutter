// commands
const String cmdFlutterRun = 'flutter.run';
const String cmdFlutterStop = 'flutter.stop';
const String cmdFlutterHotReload = 'flutter.hotReload';
const String cmdFlutterHotRestart = 'flutter.hotRestart';
const String cmdFlutterDevice = 'flutter.device';
const String cmdFlutterTools = 'flutter.tools';
const String cmdFlutterDoctor = 'flutter.doctor';
const String cmdFlutterPubGet = 'flutter.pub.get';
const String cmdFlutterClean = 'flutter.clean';
const String cmdFlutterCreate = 'flutter.create';
const String cmdFlutterSelectDevice = 'flutter.selectDevice';
const String cmdFlutterOpenDevTools = 'flutter.openDevTools';
const String cmdFlutterOpenDevToolsWebview = 'flutter.openDevToolsWebview';

// configuration
const String confLogEntryLimit = 'flutter.logEntryLimit';
const String confHotReloadOnSave = 'flutter.hotReloadOnSave';
const String confClearLogOnHotRestart = 'flutter.clearLogOnHotRestart';

// defaults
const int defaultLogEntryLimit = 5000;
const bool defaultHotReloadOnSave = true;
const bool defaultClearLogOnHotRestart = true;

// output channels
const String channelFlutter = 'Flutter';
const String channelBuildOutput = 'Build Output';

// icons
const String iconZap = 'zap';
const String iconRefreshCw = 'refresh-cw';
const String iconStop = 'stop';
const String iconPlay = 'play';
const String iconSmartphone = 'smartphone';
const String iconGlobe = 'globe';
const String iconMonitor = 'monitor';
const String iconRefresh = 'refresh';
const String iconArchive = 'archive';
const String iconTrash = 'trash';
const String iconLayout = 'layout';

// assets
const String assetIconFlutterSolid = 'icon_flutter_solid.svg';
const String folderAssets = 'assets';

// regex
final RegExp regexVmService =
    RegExp(r'(?:available at|listening on).*(http:|ws:)[^\s]+');
final RegExp regexDevTools =
    RegExp(r'The Flutter DevTools.*available at: (http:[^\s]+)');
final RegExp regexHotReload =
    RegExp(r'Reloaded (\d+) of (\d+) libraries in (\d+)ms');
final RegExp regexHotRestart = RegExp(r'Restarted application in ([\d,]+)ms');
