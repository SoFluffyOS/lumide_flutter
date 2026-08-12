import 'package:lumide_import_assist/lumide_import_assist.dart' as assist;

export 'package:lumide_import_assist/lumide_import_assist.dart'
    show ImportSyncResult, insertImports, removeImports;

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

/// Flutter-specific import detection pack for [assist].
class FlutterImportPack implements assist.ImportPack {
  const FlutterImportPack();

  @override
  String get id => 'flutter';

  @override
  assist.ImportSyntax get syntax => assist.dartImportSyntax;

  @override
  Set<String> get managedUris => managedImportUriSet;

  @override
  Set<String> detectNeeded(String source, {String? path}) =>
      detectImportUris(source, path: path);
}

const flutterImportPack = FlutterImportPack();

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

/// Returns package URIs needed by [source] but not yet imported/exported.
Set<String> neededImports(String source, {String? path}) =>
    assist.neededImports(source, flutterImportPack, path: path);

/// Managed import URIs present as `import` directives but not needed by usage.
Set<String> unusedImports(String source, {String? path}) =>
    assist.unusedImports(source, flutterImportPack, path: path);

/// Removes unused managed imports, then adds any still missing.
assist.ImportSyncResult syncImports(
  String source, {
  String? path,
  bool removeUnused = true,
}) =>
    assist.syncImports(
      source,
      flutterImportPack,
      path: path,
      removeUnused: removeUnused,
    );

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
