import 'dart:io';

import 'package:lumide_flutter/src/services/raccoon_views_entry.dart';
import 'package:path/path.dart' as path;

/// How a run on a Raccoon device starts: in views mode, from the generated
/// entry, so Lumide's Add View opens one more view of the running app at
/// once instead of starting a second run.
sealed class RaccoonViewsPlan {
  const RaccoonViewsPlan();
}

/// The run starts from [target], relative to the project, with
/// [environment] for the runner.
final class RaccoonViewsEntry extends RaccoonViewsPlan {
  const RaccoonViewsEntry(this.target);

  final String target;

  Map<String, String> get environment => RaccoonViewsLaunch.environment;
}

/// The run starts from the app's own main, for [reason]; null when views
/// were never in question (not a Raccoon device, not this host).
final class RaccoonViewsSkipped extends RaccoonViewsPlan {
  const RaccoonViewsSkipped([this.reason]);

  final String? reason;
}

/// Decides whether a run starts in views mode, and writes its entry.
///
/// Only on macOS and Linux, where views draw on the GPU (Windows has no
/// Vulkan view target yet), and only in debug. An app the entry can't wrap
/// keeps its own main, and says why:
/// - one that installs a binding of its own: the entry's is there first;
/// - one that runs in a zone of its own (`runZonedGuarded`): the binding
///   would be made outside it, a "Zone mismatch".
///
/// A global key the app holds (an app-wide navigator key) only matters at a
/// second view: the entry refuses that view and the first goes on.
abstract final class RaccoonViewsLaunch {
  /// What tells the runner to take views.
  static const environment = {'RACCOON_VIEWS': '1'};

  /// Where the entry goes, relative to the project.
  static final entryPath = path.join(
    '.dart_tool',
    'raccoon',
    'views_main.dart',
  );

  static final _ownBinding = RegExp(
    r'\b(?:extends|with)\s+[^{;]*\b(?:BindingBase|WidgetsFlutterBinding|'
    r'WidgetsBinding|RendererBinding|SchedulerBinding|ServicesBinding|'
    r'GestureBinding|PaintingBinding|SemanticsBinding)\b',
  );

  static final _otherBinding = RegExp(r'\b(\w+Binding)\.ensureInitialized\(');

  static final _ownZone = RegExp(
    r'\brunZonedGuarded\b|\bdebugZoneErrorsAreFatal\b',
  );

  /// Whether [deviceId] is a Raccoon device: `raccoon`, or one added beside
  /// it, `raccoon-tablet`.
  static bool isRaccoonDevice(String deviceId) =>
      deviceId == 'raccoon' || deviceId.startsWith('raccoon-');

  /// Whether views draw on the GPU on [operatingSystem].
  static bool takesViewsOn(String operatingSystem) =>
      operatingSystem == 'macos' || operatingSystem == 'linux';

  /// How a run of the project at [projectDirectory], whose main is
  /// [target] (relative to it), on [deviceId] starts. [buildMode] is
  /// `debug`, `profile` or `release`; [environment] is what the run is
  /// given, where a `RACCOON_VIEWS` of the user's own wins.
  static Future<RaccoonViewsPlan> plan({
    required String projectDirectory,
    required String target,
    required String deviceId,
    required String buildMode,
    Map<String, String> environment = const {},
    bool enabled = true,
    String? operatingSystem,
  }) async {
    final isCandidate =
        enabled &&
        isRaccoonDevice(deviceId) &&
        takesViewsOn(operatingSystem ?? Platform.operatingSystem) &&
        buildMode == 'debug' &&
        !environment.containsKey('RACCOON_VIEWS');
    if (!isCandidate) {
      return const RaccoonViewsSkipped();
    }

    final package = await _packageOf(projectDirectory);
    final relative = path.posix.joinAll(path.split(path.normalize(target)));
    if (package == null || !relative.startsWith('lib/')) {
      return const RaccoonViewsSkipped('its main is not in lib/ of a package');
    }

    if (await _blocker(path.join(projectDirectory, 'lib')) case final reason?) {
      return RaccoonViewsSkipped(reason);
    }

    final source = raccoonViewsEntrySource(
      'package:$package/${relative.substring(4)}',
    );
    try {
      await _write(path.join(projectDirectory, entryPath), source);
    } on FileSystemException catch (error) {
      return RaccoonViewsSkipped('its entry could not be written: $error');
    }
    return RaccoonViewsEntry(entryPath);
  }

  /// Why the app in [libDirectory] can't start from the entry, or null.
  static Future<String?> _blocker(String libDirectory) async {
    final directory = Directory(libDirectory);
    if (!await directory.exists()) {
      return null;
    }

    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }

      final String source;
      try {
        source = await entity.readAsString();
      } on FileSystemException {
        continue;
      }

      final name = path.relative(entity.path, from: path.dirname(libDirectory));
      if (_ownBinding.hasMatch(source)) {
        return 'it installs a binding of its own ($name)';
      }
      for (final match in _otherBinding.allMatches(source)) {
        if (match.group(1) case final binding?
            when binding != 'WidgetsFlutterBinding') {
          return 'it installs a binding of its own ($binding in $name)';
        }
      }
      if (_ownZone.hasMatch(source)) {
        return 'it runs in a zone of its own (runZonedGuarded in $name)';
      }
    }
    return null;
  }

  static Future<String?> _packageOf(String projectDirectory) async {
    final pubspec = File(path.join(projectDirectory, 'pubspec.yaml'));
    try {
      return RegExp(
        r'^name:\s*([A-Za-z0-9_]+)',
        multiLine: true,
      ).firstMatch(await pubspec.readAsString())?.group(1);
    } on FileSystemException {
      return null;
    }
  }

  /// Writes [source] to [filePath] unless it holds it already: a rewrite
  /// would make the tool compile it anew.
  static Future<void> _write(String filePath, String source) async {
    final file = File(filePath);
    if (await file.exists() && await file.readAsString() == source) {
      return;
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(source);
  }
}
