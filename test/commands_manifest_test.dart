import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/commands.dart';
import 'package:test/test.dart';

void main() {
  final manifest = LumideManifest.fromYaml(
    File('plugin.yaml').readAsStringSync(),
  );

  test('plugin.yaml lists every public command with its runtime title', () {
    final manifestTitles = {
      for (final command in manifest.commands) command.id: command.title,
    };
    final publicTitles = {
      for (final entry in flutterCommandTitles.entries)
        if (!internalFlutterCommands.contains(entry.key))
          entry.key: entry.value,
    };

    expect(manifestTitles, publicTitles);
  });

  test('command titles are unique', () {
    final titles = flutterCommandTitles.values.toList();
    expect(titles.toSet().length, titles.length);
  });

  test('keybindings point at registered commands', () {
    for (final binding in manifest.keybindings) {
      expect(flutterCommandTitles, contains(binding.command));
    }
  });
}
