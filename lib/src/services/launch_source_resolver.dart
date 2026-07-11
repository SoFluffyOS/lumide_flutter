import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:path/path.dart' as path;

LumideLaunchResolution resolveFlutterLaunchSource(
  LumideLaunchSourceConfiguration source, {
  required String projectRoot,
  required String? selectedDeviceId,
  required String deviceLabel,
  required String deviceTooltip,
  required String deviceIcon,
}) {
  if (source.providerId != launchProviderFlutter) {
    return const LumideLaunchResolution();
  }
  final diagnostics = <LumideLaunchConfigurationDiagnostic>[];
  final config = source.config;
  final target = _string(config, 'target') ??
      _string(config, 'program') ??
      'lib/main.dart';
  final cwd = _string(config, 'cwd');
  final deviceId = _string(config, 'deviceId');
  final flavor = _string(config, 'flavor') ?? _string(config, 'flavorName');
  final buildMode =
      _string(config, 'buildMode') ?? _string(config, 'flutterMode');
  if (buildMode != null && !_buildModes.contains(buildMode.toLowerCase())) {
    diagnostics.add(
      const LumideLaunchConfigurationDiagnostic(
        severity: LumideLaunchDiagnosticSeverity.error,
        message: 'buildMode must be debug, profile, or release.',
        path: r'$.config.buildMode',
      ),
    );
  }
  final toolArgs = _stringList(config, 'toolArgs', diagnostics);
  final args = _stringList(config, 'args', diagnostics);
  final env = _stringMap(config, 'env', diagnostics);
  final kinds = source.kinds.isEmpty
      ? const [LumideLaunchKind.run, LumideLaunchKind.debug]
      : source.kinds;
  if (diagnostics.any(
    (diagnostic) => diagnostic.severity == LumideLaunchDiagnosticSeverity.error,
  )) {
    return LumideLaunchResolution(diagnostics: diagnostics);
  }
  final resolvedCwd = _resolveWorkspacePath(cwd, projectRoot);
  final targetBase = resolvedCwd ?? projectRoot;
  final resolvedTarget =
      _resolveWorkspacePath(target, projectRoot, relativeBase: targetBase) ??
          target;
  final launchTarget = target.contains(r'${') ? target : resolvedTarget;
  return LumideLaunchResolution(
    configuration: LumideLaunchConfiguration(
      id: source.id,
      label: source.name,
      kinds: kinds,
      deduplicationKey: resolvedTarget.contains(r'${')
          ? null
          : path.normalize(resolvedTarget),
      description: path.basename(resolvedTarget),
      iconPath: assetIconFlutter,
      noTint: true,
      arguments: {
        'canLaunch': deviceId != null || selectedDeviceId != null,
        'target': launchTarget,
        if (cwd != null) 'cwd': cwd,
        if (deviceId != null) 'deviceId': deviceId,
        if (flavor != null) 'flavor': flavor,
        if (buildMode != null) 'buildMode': buildMode.toLowerCase(),
        if (toolArgs.isNotEmpty) 'toolArgs': toolArgs,
        if (args.isNotEmpty) 'args': args,
        if (env.isNotEmpty) 'env': env,
        'targetLabel': source.name,
        'targetTooltip': resolvedTarget,
        'deviceLabel': deviceId ?? deviceLabel,
        'deviceTooltip': deviceId ?? deviceTooltip,
        'deviceIcon': deviceIcon,
        'hideDevicePicker': deviceId != null,
      },
    ),
    diagnostics: diagnostics,
  );
}

String? _resolveWorkspacePath(
  String? value,
  String workspaceRoot, {
  String? relativeBase,
}) {
  if (value == null || value.isEmpty) return null;
  final expanded = value
      .replaceAll(r'${workspaceFolder}', workspaceRoot)
      .replaceAll(r'${workspaceRoot}', workspaceRoot);
  if (expanded.contains(r'${')) return expanded;
  if (path.isAbsolute(expanded)) return path.normalize(expanded);
  return path.normalize(path.join(relativeBase ?? workspaceRoot, expanded));
}

String? _string(Map<String, Object?> config, String key) {
  final value = config[key];
  if (value is String && value.isNotEmpty) return value;
  return null;
}

List<String> _stringList(
  Map<String, Object?> config,
  String key,
  List<LumideLaunchConfigurationDiagnostic> diagnostics,
) {
  final value = config[key];
  if (value == null) return const [];
  if (value is List && value.every((item) => item is String)) {
    return value.cast<String>();
  }
  diagnostics.add(
    LumideLaunchConfigurationDiagnostic(
      severity: LumideLaunchDiagnosticSeverity.error,
      message: '$key must be an array of strings.',
      path: '\$.config.$key',
    ),
  );
  return const [];
}

Map<String, String> _stringMap(
  Map<String, Object?> config,
  String key,
  List<LumideLaunchConfigurationDiagnostic> diagnostics,
) {
  final value = config[key];
  if (value == null) return const {};
  if (value is Map && value.values.every((item) => item is String)) {
    return value.map(
      (mapKey, mapValue) => MapEntry(mapKey.toString(), mapValue as String),
    );
  }
  diagnostics.add(
    LumideLaunchConfigurationDiagnostic(
      severity: LumideLaunchDiagnosticSeverity.error,
      message: '$key must contain string values.',
      path: '\$.config.$key',
    ),
  );
  return const {};
}

const _buildModes = {'debug', 'profile', 'release'};

Future<LumideLaunchImportResult> importVscodeFlutterLaunch(
  LumideForeignLaunchConfiguration source,
) async {
  final raw = source.raw;
  final type = raw['type']?.toString();
  final request = raw['request']?.toString();
  if (source.format != 'vscode' || type != 'dart') {
    return const LumideLaunchImportResult(
      fidelity: LumideLaunchImportFidelity.unsupported,
    );
  }
  if (request != 'launch') {
    return LumideLaunchImportResult(
      fidelity: LumideLaunchImportFidelity.unsupported,
      diagnostics: [
        LumideLaunchConfigurationDiagnostic(
          severity: LumideLaunchDiagnosticSeverity.error,
          message: 'VS Code Dart request "$request" is not supported.',
        ),
      ],
    );
  }
  final diagnostics = <LumideLaunchConfigurationDiagnostic>[];
  if (_containsUnsupportedVariable(raw)) {
    return const LumideLaunchImportResult(
      fidelity: LumideLaunchImportFidelity.unsupported,
      diagnostics: [
        LumideLaunchConfigurationDiagnostic(
          severity: LumideLaunchDiagnosticSeverity.error,
          message:
              'Command and input variables require manual migration in Lumide.',
        ),
      ],
    );
  }
  const unsupportedFields = {'preLaunchTask', 'postDebugTask', 'envFile'};
  for (final field in unsupportedFields) {
    if (raw.containsKey(field)) {
      diagnostics.add(
        LumideLaunchConfigurationDiagnostic(
          severity: LumideLaunchDiagnosticSeverity.warning,
          message: 'VS Code field "$field" requires manual migration.',
          path: '\$.$field',
        ),
      );
    }
  }
  final config = <String, Object?>{
    'target': raw['program']?.toString() ?? 'lib/main.dart',
    if (raw['cwd'] case final String cwd) 'cwd': cwd,
    if (raw['deviceId'] case final String deviceId) 'deviceId': deviceId,
    if (raw['flutterMode'] case final String mode) 'buildMode': mode,
    if (raw['flavorName'] case final String flavor) 'flavor': flavor,
    if (raw['toolArgs'] case final List toolArgs) 'toolArgs': toolArgs,
    if (raw['args'] case final List args) 'args': args,
    if (raw['env'] case final Map env)
      'env': env.map((key, value) => MapEntry(key.toString(), value)),
  };
  final id = source.name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return LumideLaunchImportResult(
    fidelity: switch (diagnostics.isEmpty) {
      true => LumideLaunchImportFidelity.exact,
      false => LumideLaunchImportFidelity.partial,
    },
    configuration: LumideLaunchSourceConfiguration(
      id: id,
      name: source.name,
      providerId: launchProviderFlutter,
      kinds: const [LumideLaunchKind.run, LumideLaunchKind.debug],
      config: config,
    ),
    diagnostics: diagnostics,
  );
}

bool _containsUnsupportedVariable(Object? value) {
  return switch (value) {
    final String text =>
      text.contains(r'${command:') || text.contains(r'${input:'),
    final List values => values.any(_containsUnsupportedVariable),
    final Map values => values.values.any(_containsUnsupportedVariable),
    _ => false,
  };
}
