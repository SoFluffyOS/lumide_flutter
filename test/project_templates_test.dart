import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';

LumideProjectCreateRequest _request(
  FlutterProjectTemplate template, [
  Map<String, Object?> values = const {},
]) =>
    LumideProjectCreateRequest(
      templateId: template.id,
      name: 'My App',
      packageName: 'my_app',
      parent: '/projects',
      path: '/projects/My App',
      values: values,
    );

void main() {
  final manifest = LumideManifest.fromYaml(
    File('plugin.yaml').readAsStringSync(),
  );

  test('plugin.yaml declares every template, each starting the plugin', () {
    expect(
      [for (final template in manifest.projectTemplates) template.id],
      [for (final template in FlutterProjectTemplate.values) template.id],
    );
    for (final template in FlutterProjectTemplate.values) {
      expect(
        manifest.activationEvents,
        contains('onProjectTemplate:${template.id}'),
      );
    }
  });

  test('a template takes a Dart package name, and its fields parse', () {
    final app = manifest.projectTemplates.first;
    final name = RegExp(app.namePattern ?? '');
    expect(
      manifest.projectTemplates.every((template) => template.packageName),
      isTrue,
    );

    expect(name.hasMatch('my_app'), isTrue);
    expect(name.hasMatch('my_app_'), isFalse);
    expect(name.hasMatch('1app'), isFalse);
    expect([
      for (final field in app.fields) field.id
    ], [
      'platforms',
      'org',
      'description',
      'androidLanguage',
      'pub',
      'offline',
    ]);

    final org = app.fields[1];
    expect(RegExp(org.pattern ?? '').hasMatch('dev.lumide'), isTrue);
    expect(RegExp(org.pattern ?? '').hasMatch('lumide'), isFalse);

    final plugin = manifest.projectTemplates.firstWhere(
      (template) => template.id == FlutterProjectTemplate.plugin.id,
    );
    expect(plugin.fields.first.defaultValue, ['android', 'ios']);
  });

  test('the values become flutter create arguments', () {
    expect(
      FlutterProjectTemplate.app.createArgs(
        _request(FlutterProjectTemplate.app, {
          'platforms': ['ios', 'macos'],
          'org': 'dev.lumide',
          'description': '',
          'androidLanguage': 'java',
          'pub': false,
          'offline': true,
        }),
      ),
      [
        'create',
        '--template',
        'app',
        '--platforms',
        'ios,macos',
        '--org',
        'dev.lumide',
        '--android-language',
        'java',
        '--no-pub',
        '--offline',
        '--project-name',
        'my_app',
        'My App',
      ],
    );
    expect(
      FlutterProjectTemplate.empty.createArgs(
        _request(FlutterProjectTemplate.empty),
      ),
      ['create', '--empty', '--project-name', 'my_app', 'My App'],
    );
  });

  test('creating runs flutter in the parent folder and opens the entry file',
      () async {
    final runs = <(String, List<String>, String?)>[];
    final creator = FlutterProjectCreator(
      (projectRoot, arguments, {workingDirectory}) async {
        runs.add((projectRoot, arguments, workingDirectory));
        return const ProcessResult(exitCode: 0, stdout: '', stderr: '');
      },
    );

    final created = await creator.create(
      _request(FlutterProjectTemplate.package),
    );

    expect(created.openFiles, ['lib/my_app.dart']);
    final [(root, arguments, folder)] = runs;
    expect(root, '/projects');
    expect(folder, '/projects');
    expect(arguments.take(3), ['create', '--template', 'package']);
  });

  test("a failure shows the tool's last lines", () async {
    final creator = FlutterProjectCreator(
      (projectRoot, arguments, {workingDirectory}) async => const ProcessResult(
        exitCode: 64,
        stdout: '',
        stderr: 'one\ntwo\nthree\nfour\nfive',
      ),
    );

    await expectLater(
      creator.create(_request(FlutterProjectTemplate.app)),
      throwsA(
        predicate<Exception>(
          (error) => '$error' == 'Exception: two\nthree\nfour\nfive',
        ),
      ),
    );
  });
}
