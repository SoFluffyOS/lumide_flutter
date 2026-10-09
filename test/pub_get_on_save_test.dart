import 'dart:async';

import 'package:lumide_flutter/src/services/pub_get_on_save.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  const debounce = Duration(milliseconds: 10);
  final packageRoot = path.join(path.current, 'packages', 'app');
  final pubspecUri = Uri.file(path.join(packageRoot, 'pubspec.yaml')).toString();

  Future<void> settle() => Future<void>.delayed(debounce * 4);

  test('runs once for a burst of saves', () async {
    final runs = <String>[];
    final watcher = PubGetOnSave(
      debounce: debounce,
      isEnabled: () async => true,
      pubGet: (root) async => runs.add(root),
    );
    addTearDown(watcher.dispose);

    watcher
      ..handleSave(pubspecUri)
      ..handleSave(pubspecUri)
      ..handleSave(pubspecUri);
    await settle();

    expect(runs, [packageRoot]);
  });

  test('ignores other files and non-file URIs', () async {
    var runs = 0;
    final watcher = PubGetOnSave(
      debounce: debounce,
      isEnabled: () async => true,
      pubGet: (_) async => runs++,
    );
    addTearDown(watcher.dispose);

    watcher
      ..handleSave(Uri.file(path.join(packageRoot, 'lib', 'main.dart'))
          .toString())
      ..handleSave('untitled:pubspec.yaml');
    await settle();

    expect(runs, 0);
  });

  test('respects the setting', () async {
    var runs = 0;
    final watcher = PubGetOnSave(
      debounce: debounce,
      isEnabled: () async => false,
      pubGet: (_) async => runs++,
    );
    addTearDown(watcher.dispose);

    watcher.handleSave(pubspecUri);
    await settle();

    expect(runs, 0);
  });

  test('queues one follow-up when saved during a run', () async {
    var runs = 0;
    final firstRun = Completer<void>();
    final watcher = PubGetOnSave(
      debounce: debounce,
      isEnabled: () async => true,
      pubGet: (_) {
        runs++;
        if (runs == 1) return firstRun.future;
        return Future.value();
      },
    );
    addTearDown(watcher.dispose);

    watcher.handleSave(pubspecUri);
    await settle();
    watcher.handleSave(pubspecUri);
    await settle();
    watcher.handleSave(pubspecUri);
    await settle();
    expect(runs, 1);

    firstRun.complete();
    await settle();
    expect(runs, 2);
  });
}
