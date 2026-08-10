// Pure helpers for detecting and inserting Flutter-related imports.

const String importFlutterMaterial = 'package:flutter/material.dart';
const String importFlutterCupertino = 'package:flutter/cupertino.dart';
const String importFlutterWidgets = 'package:flutter/widgets.dart';
const String importFlutterServices = 'package:flutter/services.dart';
const String importFlutterPainting = 'package:flutter/painting.dart';
const String importFlutterFoundation = 'package:flutter/foundation.dart';
const String importFlutterRendering = 'package:flutter/rendering.dart';
const String importFlutterTest = 'package:flutter_test/flutter_test.dart';

const List<String> managedImportUris = [
  importFlutterMaterial,
  importFlutterCupertino,
  importFlutterWidgets,
  importFlutterServices,
  importFlutterPainting,
  importFlutterFoundation,
  importFlutterRendering,
  importFlutterTest,
];

final Set<String> managedImportUriSet = Set<String>.unmodifiable(
  managedImportUris,
);

/// Result of adding missing and/or removing unused managed imports.
class ImportSyncResult {
  const ImportSyncResult({
    required this.source,
    this.added = const {},
    this.removed = const {},
  });

  final String source;
  final Set<String> added;
  final Set<String> removed;

  bool get isNoOp => added.isEmpty && removed.isEmpty;
}

final _importOrExportOrPart = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

final _importDirectiveOnly = RegExp(
  r'''^\s*import\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Returns package URIs that appear to be needed by [source] but are not yet
/// imported/exported.
Set<String> neededImports(String source, {String? path}) {
  final existing = existingImportUris(source);
  final detected = detectImportUris(source, path: path);
  return detected.difference(existing);
}

/// Managed import URIs present as `import` directives but not needed by usage.
Set<String> unusedImports(String source, {String? path}) {
  final existing = existingImportDirectiveUris(source);
  final detected = detectImportUris(source, path: path);
  return existing.intersection(managedImportUriSet).difference(detected);
}

/// Removes unused managed imports, then adds any still missing.
ImportSyncResult syncImports(
  String source, {
  String? path,
  bool removeUnused = true,
}) {
  final detected = detectImportUris(source, path: path);
  final toRemove = removeUnused ? unusedImports(source, path: path) : <String>{};
  var next = removeImports(source, toRemove);
  final toAdd = detected.difference(existingImportUris(next));
  next = insertImports(next, toAdd);
  return ImportSyncResult(source: next, added: toAdd, removed: toRemove);
}

/// Detects which Flutter-related import URIs [source] likely needs.
Set<String> detectImportUris(String source, {String? path}) {
  final needed = <String>{};
  final fileName =
      path == null ? '' : path.replaceAll('\\', '/').split('/').last;
  final isTestFile = fileName.endsWith('_test.dart');

  final needsMaterial = _hasAny(source, _materialMarkers);
  final needsCupertino = _hasAny(source, _cupertinoMarkers);
  // material/cupertino re-export widgets and most painting/foundation/services.
  final coveredByUiLibrary = needsMaterial || needsCupertino;

  if (needsMaterial) {
    needed.add(importFlutterMaterial);
  }
  if (needsCupertino) {
    needed.add(importFlutterCupertino);
  }
  if (!coveredByUiLibrary) {
    if (_hasAny(source, _widgetsMarkers)) {
      needed.add(importFlutterWidgets);
    }
    if (_hasAny(source, _servicesMarkers)) {
      needed.add(importFlutterServices);
    }
    if (_hasAny(source, _paintingMarkers)) {
      needed.add(importFlutterPainting);
    }
    if (_hasAny(source, _foundationMarkers)) {
      needed.add(importFlutterFoundation);
    }
    if (_hasAny(source, _renderingMarkers)) {
      needed.add(importFlutterRendering);
    }
  }
  if (isTestFile && _hasAny(source, _flutterTestMarkers)) {
    needed.add(importFlutterTest);
  }

  return needed;
}

Set<String> existingImportUris(String source) {
  final uris = <String>{};
  for (final match in _importOrExportOrPart.allMatches(source)) {
    final uri = match.group(1);
    if (uri != null && uri.isNotEmpty) {
      uris.add(uri);
    }
  }
  return uris;
}

/// URIs from `import` directives only (not `export` / `part`).
Set<String> existingImportDirectiveUris(String source) {
  final uris = <String>{};
  for (final match in _importDirectiveOnly.allMatches(source)) {
    final uri = match.group(1);
    if (uri != null && uri.isNotEmpty) {
      uris.add(uri);
    }
  }
  return uris;
}

/// Removes whole `import 'uri'…;` lines for [uris]. Does not touch exports.
String removeImports(String source, Set<String> uris) {
  if (uris.isEmpty) return source;

  final lines = source.split('\n');
  final kept = <String>[];
  for (final line in lines) {
    final uri = _importUriFromLine(line);
    if (uri != null && uris.contains(uri)) {
      continue;
    }
    kept.add(line);
  }

  // Collapse excessive blank lines left at the top of the file.
  final collapsed = <String>[];
  var leadingBlank = true;
  var previousBlank = false;
  for (final line in kept) {
    final isBlank = line.trim().isEmpty;
    if (leadingBlank && isBlank) continue;
    if (isBlank && previousBlank) continue;
    leadingBlank = false;
    previousBlank = isBlank;
    collapsed.add(line);
  }
  return collapsed.join('\n');
}

String? _importUriFromLine(String line) {
  final match = RegExp(
    r'''^\s*import\s+['"]([^'"]+)['"][^;]*;\s*$''',
  ).firstMatch(line);
  return match?.group(1);
}

/// Inserts missing `import '…';` lines after the last directive block.
/// Returns [source] unchanged when [uris] is empty.
String insertImports(String source, Set<String> uris) {
  if (uris.isEmpty) return source;

  final sorted = uris.toList()..sort((a, b) => a.compareTo(b));
  final importBlock = sorted.map((uri) => "import '$uri';").join('\n');

  final lines = source.split('\n');
  var lastDirectiveIndex = -1;
  var sawLibrary = false;

  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('//') || trimmed.startsWith('/*')) continue;
    if (trimmed.startsWith('library ')) {
      sawLibrary = true;
      lastDirectiveIndex = i;
      continue;
    }
    if (trimmed.startsWith('import ') ||
        trimmed.startsWith('export ') ||
        trimmed.startsWith('part ')) {
      lastDirectiveIndex = i;
      continue;
    }
    break;
  }

  if (lastDirectiveIndex >= 0) {
    lines.insert(lastDirectiveIndex + 1, importBlock);
    return lines.join('\n');
  }

  if (sawLibrary) {
    return '$importBlock\n\n$source';
  }

  if (source.isEmpty) return '$importBlock\n';
  return '$importBlock\n\n$source';
}

bool _hasAny(String source, List<RegExp> patterns) {
  for (final pattern in patterns) {
    if (pattern.hasMatch(source)) return true;
  }
  return false;
}

final _materialMarkers = <RegExp>[
  RegExp(r'\bMaterialApp\b'),
  RegExp(r'\bMaterial\b'),
  RegExp(r'\bScaffold\b'),
  RegExp(r'\bAppBar\b'),
  RegExp(r'\bThemeData\b'),
  RegExp(r'\bTheme\b'),
  RegExp(r'\bColors\.'),
  RegExp(r'\bIcons\.'),
  RegExp(r'\bElevatedButton\b'),
  RegExp(r'\bTextButton\b'),
  RegExp(r'\bOutlinedButton\b'),
  RegExp(r'\bFloatingActionButton\b'),
  RegExp(r'\bIconButton\b'),
  RegExp(r'\bCard\b'),
  RegExp(r'\bDrawer\b'),
  RegExp(r'\bBottomNavigationBar\b'),
  RegExp(r'\bSnackBar\b'),
  RegExp(r'\bAlertDialog\b'),
  RegExp(r'\bshowDialog\b'),
  RegExp(r'\bshowModalBottomSheet\b'),
  RegExp(r'\bCircularProgressIndicator\b'),
  RegExp(r'\bLinearProgressIndicator\b'),
  RegExp(r'\bListTile\b'),
  RegExp(r'\bTextField\b'),
  RegExp(r'\bTextFormField\b'),
  RegExp(r'\bInputDecoration\b'),
  RegExp(r'\bDropdownButton\b'),
  RegExp(r'\bCheckbox\b'),
  RegExp(r'\bSwitch\b'),
  RegExp(r'\bSlider\b'),
  RegExp(r'\bChip\b'),
  RegExp(r'\bTabBar\b'),
  RegExp(r'\bTabBarView\b'),
  RegExp(r'\bNavigator\.'),
  RegExp(r'\bMaterialPageRoute\b'),
  RegExp(r'\bSafeArea\b'),
  RegExp(r'\bInkWell\b'),
  RegExp(r'\bGestureDetector\b'),
];

final _cupertinoMarkers = <RegExp>[
  RegExp(r'\bCupertinoApp\b'),
  RegExp(r'\bCupertinoPageScaffold\b'),
  RegExp(r'\bCupertinoNavigationBar\b'),
  RegExp(r'\bCupertinoButton\b'),
  RegExp(r'\bCupertinoIcons\.'),
  RegExp(r'\bCupertinoColors\.'),
  RegExp(r'\bCupertinoAlertDialog\b'),
  RegExp(r'\bCupertinoActivityIndicator\b'),
  RegExp(r'\bCupertinoSwitch\b'),
  RegExp(r'\bCupertinoSlider\b'),
  RegExp(r'\bCupertinoTabBar\b'),
  RegExp(r'\bCupertinoTabScaffold\b'),
  RegExp(r'\bCupertinoPageRoute\b'),
  RegExp(r'\bshowCupertinoDialog\b'),
  RegExp(r'\bshowCupertinoModalPopup\b'),
];

final _widgetsMarkers = <RegExp>[
  RegExp(r'\bStatelessWidget\b'),
  RegExp(r'\bStatefulWidget\b'),
  RegExp(r'\bState\s*<'),
  RegExp(r'\bBuildContext\b'),
  RegExp(r'\bWidget\b'),
  RegExp(r'\bPlaceholder\b'),
  RegExp(r'\bContainer\b'),
  RegExp(r'\bColumn\b'),
  RegExp(r'\bRow\b'),
  RegExp(r'\bStack\b'),
  RegExp(r'\bSizedBox\b'),
  RegExp(r'\bPadding\b'),
  RegExp(r'\bCenter\b'),
  RegExp(r'\bExpanded\b'),
  RegExp(r'\bFlexible\b'),
  RegExp(r'\bListView\b'),
  RegExp(r'\bGridView\b'),
  RegExp(r'\bSingleChildScrollView\b'),
  RegExp(r'\bText\s*\('),
  RegExp(r'\bImage\.'),
  RegExp(r'\bIcon\s*\('),
  RegExp(r'\bKey\b'),
  RegExp(r'\bValueKey\b'),
  RegExp(r'\bGlobalKey\b'),
  RegExp(r'\bAnimationController\b'),
  RegExp(r'\bSingleTickerProviderStateMixin\b'),
  RegExp(r'\bTickerProviderStateMixin\b'),
];

final _servicesMarkers = <RegExp>[
  RegExp(r'\bMethodChannel\b'),
  RegExp(r'\bEventChannel\b'),
  RegExp(r'\bBasicMessageChannel\b'),
  RegExp(r'\bClipboard\b'),
  RegExp(r'\bSystemChrome\b'),
  RegExp(r'\bSystemNavigator\b'),
  RegExp(r'\bHapticFeedback\b'),
  RegExp(r'\bTextInput\b'),
  RegExp(r'\bRawKeyboard\b'),
  RegExp(r'\bHardwareKeyboard\b'),
  RegExp(r'\bLogicalKeyboardKey\b'),
  RegExp(r'\bPlatformException\b'),
];

final _paintingMarkers = <RegExp>[
  RegExp(r'\bEdgeInsets\b'),
  RegExp(r'\bBorderRadius\b'),
  RegExp(r'\bBoxDecoration\b'),
  RegExp(r'\bBoxShadow\b'),
  RegExp(r'\bLinearGradient\b'),
  RegExp(r'\bRadialGradient\b'),
  RegExp(r'\bTextStyle\b'),
  RegExp(r'\bTextSpan\b'),
  RegExp(r'\bTextPainter\b'),
  RegExp(r'\bAssetImage\b'),
  RegExp(r'\bNetworkImage\b'),
  RegExp(r'\bMemoryImage\b'),
  RegExp(r'\bDecorationImage\b'),
  RegExp(r'\bColorFilter\b'),
];

final _foundationMarkers = <RegExp>[
  RegExp(r'\bkDebugMode\b'),
  RegExp(r'\bkReleaseMode\b'),
  RegExp(r'\bkProfileMode\b'),
  RegExp(r'\bkIsWeb\b'),
  RegExp(r'@immutable\b'),
  RegExp(r'\bChangeNotifier\b'),
  RegExp(r'\bValueNotifier\b'),
  RegExp(r'\bValueListenable\b'),
  RegExp(r'\bListenable\b'),
  RegExp(r'\bDiagnosticable\b'),
  RegExp(r'\bdebugPrint\b'),
  RegExp(r'\bFlutterError\b'),
];

final _renderingMarkers = <RegExp>[
  RegExp(r'\bRenderBox\b'),
  RegExp(r'\bRenderObject\b'),
  RegExp(r'\bRenderParagraph\b'),
  RegExp(r'\bCustomPainter\b'),
  RegExp(r'\bCustomPaint\b'),
  RegExp(r'\bHitTestResult\b'),
  RegExp(r'\bPipelineOwner\b'),
];

final _flutterTestMarkers = <RegExp>[
  RegExp(r'\btestWidgets\s*\('),
  RegExp(r'\bpumpWidget\s*\('),
  RegExp(r'\bWidgetTester\b'),
  RegExp(r'\bfindsOneWidget\b'),
  RegExp(r'\bfindsNothing\b'),
  RegExp(r'\bfindsWidgets\b'),
  RegExp(r'\bfind\.'),
];
