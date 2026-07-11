import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/launch_source_resolver.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('normalizes native Flutter launch fields', () {
    const source = LumideLaunchSourceConfiguration(
      id: 'dev',
      name: 'Flutter Dev',
      providerId: 'flutter',
      kinds: [LumideLaunchKind.run, LumideLaunchKind.debug],
      config: {
        'target': 'lib/dev.dart',
        'cwd': r'${workspaceFolder}',
        'deviceId': 'chrome',
        'buildMode': 'PROFILE',
        'flavor': 'dev',
        'toolArgs': ['--dart-define', 'ENV=dev'],
        'args': ['--seed', 'demo'],
        'env': {'LOG_LEVEL': 'debug'},
      },
    );

    final result = resolveFlutterLaunchSource(
      source,
      projectRoot: '/workspace',
      selectedDeviceId: 'macos',
      deviceLabel: 'macOS',
      deviceTooltip: 'Local macOS',
      deviceIcon: 'laptop',
    );

    expect(result.diagnostics, isEmpty);
    final configuration = result.configuration;
    expect(configuration?.arguments['target'],
        path.join('/workspace', 'lib/dev.dart'));
    expect(configuration?.arguments['cwd'], r'${workspaceFolder}');
    expect(configuration?.arguments['buildMode'], 'profile');
    expect(configuration?.arguments['args'], ['--seed', 'demo']);
    expect(configuration?.arguments['env'], {'LOG_LEVEL': 'debug'});
    expect(configuration?.supportedKinds, source.kinds);
  });

  test('preserves host variables until launch-time resolution', () {
    const source = LumideLaunchSourceConfiguration(
      id: 'main',
      name: 'Main',
      providerId: 'flutter',
      kinds: [LumideLaunchKind.run],
      config: {'target': r'${workspaceFolder}/lib/main.dart'},
    );

    final result = resolveFlutterLaunchSource(
      source,
      projectRoot: '/workspace',
      selectedDeviceId: 'macos',
      deviceLabel: 'macOS',
      deviceTooltip: 'Local macOS',
      deviceIcon: 'laptop',
    );

    expect(
      result.configuration?.arguments['target'],
      r'${workspaceFolder}/lib/main.dart',
    );
  });

  test('resolves relative targets from the configured working directory', () {
    const source = LumideLaunchSourceConfiguration(
      id: 'mobile',
      name: 'Flutter Main',
      providerId: 'flutter',
      config: {
        'target': 'lib/main.dart',
        'cwd': r'${workspaceFolder}/apps/mobile',
      },
    );

    final result = resolveFlutterLaunchSource(
      source,
      projectRoot: '/workspace',
      selectedDeviceId: 'chrome',
      deviceLabel: 'Chrome',
      deviceTooltip: 'Chrome',
      deviceIcon: 'monitor',
    );

    final configuration = result.configuration;
    expect(
      configuration?.arguments['cwd'],
      r'${workspaceFolder}/apps/mobile',
    );
    expect(
      configuration?.arguments['target'],
      '/workspace/apps/mobile/lib/main.dart',
    );
    expect(
      configuration?.deduplicationKey,
      '/workspace/apps/mobile/lib/main.dart',
    );
  });

  test('defaults minimal source configurations to run and debug', () {
    final result = resolveFlutterLaunchSource(
      const LumideLaunchSourceConfiguration(
        id: 'generated',
        name: 'Flutter Main',
        providerId: 'flutter',
        kinds: [],
        config: {},
      ),
      projectRoot: '/workspace',
      selectedDeviceId: 'chrome',
      deviceLabel: 'Chrome',
      deviceTooltip: 'Chrome',
      deviceIcon: 'monitor',
    );

    expect(result.configuration?.kinds, [
      LumideLaunchKind.run,
      LumideLaunchKind.debug,
    ]);
  });

  test('returns field diagnostics for invalid provider payloads', () {
    const source = LumideLaunchSourceConfiguration(
      id: 'bad',
      name: 'Bad',
      providerId: 'flutter',
      kinds: [LumideLaunchKind.run],
      config: {
        'buildMode': 'fast',
        'toolArgs': 'not-a-list',
        'env': {'PORT': 8080},
      },
    );

    final result = resolveFlutterLaunchSource(
      source,
      projectRoot: '/workspace',
      selectedDeviceId: null,
      deviceLabel: 'No device',
      deviceTooltip: 'No device',
      deviceIcon: 'circle',
    );

    expect(result.configuration, isNull);
    expect(result.diagnostics, hasLength(3));
    expect(
        result.diagnostics.map((item) => item.path),
        containsAll([
          r'$.config.buildMode',
          r'$.config.toolArgs',
          r'$.config.env',
        ]));
  });

  test('imports supported VS Code Dart launch fields exactly', () async {
    const foreign = LumideForeignLaunchConfiguration(
      format: 'vscode',
      name: 'Flutter Dev',
      raw: {
        'type': 'dart',
        'request': 'launch',
        'program': r'${workspaceFolder}/lib/dev.dart',
        'cwd': r'${workspaceFolder}',
        'flutterMode': 'debug',
        'flavorName': 'dev',
        'deviceId': 'chrome',
        'args': ['--seed', 'demo'],
        'env': {'MODE': 'dev'},
      },
    );

    final result = await importVscodeFlutterLaunch(foreign);

    expect(result.fidelity, LumideLaunchImportFidelity.exact);
    expect(result.configuration?.config['buildMode'], 'debug');
    expect(result.configuration?.config['flavor'], 'dev');
    expect(result.configuration?.config['deviceId'], 'chrome');
  });

  test('marks unsupported VS Code task fields as partial', () async {
    const foreign = LumideForeignLaunchConfiguration(
      format: 'vscode',
      name: 'Flutter',
      raw: {
        'type': 'dart',
        'request': 'launch',
        'program': 'lib/main.dart',
        'preLaunchTask': 'build',
      },
    );

    final result = await importVscodeFlutterLaunch(foreign);

    expect(result.fidelity, LumideLaunchImportFidelity.partial);
    expect(result.diagnostics.single.path, r'$.preLaunchTask');
  });

  test('rejects VS Code command variables', () async {
    const foreign = LumideForeignLaunchConfiguration(
      format: 'vscode',
      name: 'Command target',
      raw: {
        'type': 'dart',
        'request': 'launch',
        'program': r'${command:pickTarget}',
      },
    );

    final result = await importVscodeFlutterLaunch(foreign);

    expect(result.fidelity, LumideLaunchImportFidelity.unsupported);
    expect(result.configuration, isNull);
  });
}
