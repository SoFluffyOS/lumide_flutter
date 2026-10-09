import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/devtools_page.dart';

/// Commands registered at runtime but not listed in the Command Palette,
/// because they only work with arguments supplied by the host.
const Set<String> internalFlutterCommands = {cmdFlutterRunFile};

/// Titles for every command the plugin registers, keyed by command id.
///
/// `plugin.yaml` must list the same commands with the same titles, except
/// [internalFlutterCommands]; `test/commands_manifest_test.dart` enforces it.
final Map<String, String> flutterCommandTitles = {
  cmdFlutterRunFile: 'Flutter: Launch File',
  cmdFlutterShowWidgetPreview: 'Flutter: Open Widget Preview',
  cmdFlutterStopWidgetPreview: 'Flutter: Stop Widget Preview',
  cmdFlutterToggleInspector: 'Flutter: Toggle Widget Selection',
  cmdFlutterTogglePerformanceOverlay: 'Flutter: Toggle Performance Overlay',
  for (final page in DevToolsPage.values)
    page.command: 'Flutter: Open ${page.title}',
  cmdFlutterDoctor: 'Flutter: Doctor',
  cmdFlutterPubGet: 'Flutter: Pub Get',
  cmdFlutterPubUpgrade: 'Flutter: Pub Upgrade',
  cmdFlutterPubOutdated: 'Flutter: Pub Outdated',
  cmdFlutterGenL10n: 'Flutter: Generate Localizations',
  cmdFlutterBuildRunnerBuild: 'Flutter: Run build_runner',
  cmdFlutterClean: 'Flutter: Clean',
  cmdFlutterRun: 'Flutter: Run',
  cmdFlutterDebug: 'Flutter: Debug',
  cmdFlutterAttach: 'Flutter: Attach',
  cmdFlutterHotReload: 'Flutter: Hot Reload',
  cmdFlutterHotRestart: 'Flutter: Hot Restart',
  cmdFlutterStop: 'Flutter: Stop App',
  cmdFlutterCreate: 'Flutter: New Project',
  cmdFlutterSelectDevice: 'Flutter: Select Device',
  cmdFlutterSelectTarget: 'Flutter: Select Target',
  cmdFlutterSetFlavor: 'Flutter: Set Flavor',
  cmdFlutterSetBuildMode: 'Flutter: Set Build Mode',
  cmdFlutterOpenDevToolsWebview: 'Flutter: Open DevTools',
  cmdFlutterOpenDevTools: 'Flutter: Open DevTools (Browser)',
  cmdFlutterTools: 'Flutter: Tools Menu',
  cmdFlutterPubGetForContext: 'Flutter: Pub Get Here',
  cmdFlutterCleanForContext: 'Flutter: Clean Here',
  cmdFlutterSetTargetForContext: 'Flutter: Set as Target',
  cmdFlutterCreateForContext: 'Flutter: New Project Here',
  cmdFlutterNewDartFileForContext: 'Flutter: New Dart File',
};

/// Title of a registered command, falling back to its id.
String flutterCommandTitle(String id) => flutterCommandTitles[id] ?? id;
