import 'dart:io';

import 'package:lumide_flutter/src/services/launch_options_store.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String projectRoot;
  late String storageDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lumide-launch-options-');
    projectRoot = path.join(root.path, 'app');
    storageDir = path.join(root.path, 'storage');
    await Directory(projectRoot).create();
  });

  tearDown(() => root.delete(recursive: true));

  LaunchOptionsStore createStore({String? storage}) => LaunchOptionsStore(
        storageDir: () async => storage,
        projectRoot: () async => projectRoot,
      );

  test('stores values outside .dart_tool', () async {
    await createStore(storage: storageDir)
        .write(LaunchOptionsStore.flavorKey, 'staging');

    final dartTool = Directory(path.join(projectRoot, '.dart_tool'));
    expect(await dartTool.exists(), isFalse);
    final reopened = createStore(storage: storageDir);
    expect(await reopened.read(LaunchOptionsStore.flavorKey), 'staging');
  });

  test('falls back to values written by older versions', () async {
    final legacy = File(
      path.join(projectRoot, '.dart_tool', 'lumide', 'build_mode.txt'),
    );
    await legacy.create(recursive: true);
    await legacy.writeAsString('profile');

    final store = createStore(storage: storageDir);
    expect(await store.read(LaunchOptionsStore.buildModeKey), 'profile');

    await store.write(LaunchOptionsStore.buildModeKey, 'release');
    expect(await store.read(LaunchOptionsStore.buildModeKey), 'release');
  });

  test('keeps projects separate', () async {
    final store = createStore(storage: storageDir);
    await store.write(LaunchOptionsStore.targetKey, 'lib/main.dart');

    projectRoot = path.join(root.path, 'other');
    await Directory(projectRoot).create();
    expect(await store.read(LaunchOptionsStore.targetKey), isNull);
  });

  test('uses the legacy location without plugin storage', () async {
    await createStore().write(LaunchOptionsStore.toolArgsKey, '["--verbose"]');

    final legacy = File(
      path.join(projectRoot, '.dart_tool', 'lumide', 'tool_args.txt'),
    );
    expect(await legacy.readAsString(), '["--verbose"]');
  });

  test('keeps every value when writes overlap', () async {
    final store = createStore(storage: storageDir);
    await Future.wait([
      store.write(LaunchOptionsStore.flavorKey, 'dev'),
      store.write(LaunchOptionsStore.buildModeKey, 'profile'),
      store.write(LaunchOptionsStore.targetKey, 'lib/main_dev.dart'),
    ]);

    final reopened = createStore(storage: storageDir);
    expect(await reopened.read(LaunchOptionsStore.flavorKey), 'dev');
    expect(await reopened.read(LaunchOptionsStore.buildModeKey), 'profile');
    expect(
      await reopened.read(LaunchOptionsStore.targetKey),
      'lib/main_dev.dart',
    );
  });
}
