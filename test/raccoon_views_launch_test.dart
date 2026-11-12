import 'dart:io';

import 'package:lumide_flutter/src/services/services.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('raccoon_views_launch');
    File(path.join(project.path, 'pubspec.yaml'))
        .writeAsStringSync('name: wonders\n');
    _write(project, 'lib/main.dart', '''
import 'package:flutter/widgets.dart';

void main() => runApp(const SizedBox());
''');
  });
  tearDown(() => project.deleteSync(recursive: true));

  Future<RaccoonViewsPlan> plan({
    String target = 'lib/main.dart',
    String deviceId = 'raccoon',
    String buildMode = 'debug',
    Map<String, String> environment = const {},
    bool enabled = true,
    String operatingSystem = 'macos',
  }) =>
      RaccoonViewsLaunch.plan(
        projectDirectory: project.path,
        target: target,
        deviceId: deviceId,
        buildMode: buildMode,
        environment: environment,
        enabled: enabled,
        operatingSystem: operatingSystem,
      );

  String entrySource() => File(
        path.join(project.path, RaccoonViewsLaunch.entryPath),
      ).readAsStringSync();

  test('a debug run on a Raccoon device starts from the views entry', () async {
    final views = await plan();

    expect(views, isA<RaccoonViewsEntry>());
    final entry = views as RaccoonViewsEntry;
    expect(entry.target, path.join('.dart_tool', 'raccoon', 'views_main.dart'));
    expect(entry.environment, {'RACCOON_VIEWS': '1'});
    expect(
        entrySource(), contains("import 'package:wonders/main.dart' as app;"));
    expect(entrySource(), contains('wrapWithDefaultView'));
  });

  test('the entry imports the main the run was given', () async {
    _write(project, 'lib/src/dev.dart', 'void main() {}\n');

    final views = await plan(target: 'lib/src/dev.dart', deviceId: 'raccoon-2');

    expect(views, isA<RaccoonViewsEntry>());
    expect(
      entrySource(),
      contains("import 'package:wonders/src/dev.dart' as app;"),
    );
  });

  test('Linux takes views too, Windows not yet', () async {
    expect(await plan(operatingSystem: 'linux'), isA<RaccoonViewsEntry>());

    final windows = await plan(operatingSystem: 'windows');
    expect(windows, isA<RaccoonViewsSkipped>());
    expect((windows as RaccoonViewsSkipped).reason, isNull);
  });

  test(
      'other devices, other modes, the setting off or the user\'s own '
      'RACCOON_VIEWS keep the app\'s main, quietly', () async {
    for (final views in [
      await plan(deviceId: 'macos'),
      await plan(deviceId: 'pocket'),
      await plan(buildMode: 'profile'),
      await plan(buildMode: 'release'),
      await plan(enabled: false),
      await plan(environment: const {'RACCOON_VIEWS': '0'}),
    ]) {
      expect(views, isA<RaccoonViewsSkipped>());
      expect((views as RaccoonViewsSkipped).reason, isNull);
    }
    expect(
      File(path.join(project.path, RaccoonViewsLaunch.entryPath)).existsSync(),
      isFalse,
    );
  });

  test('a main outside lib says why', () async {
    final views = await plan(target: 'tool/main.dart');

    expect((views as RaccoonViewsSkipped).reason, contains('lib/'));
  });

  test('an app with a binding of its own keeps its main', () async {
    _write(project, 'lib/src/binding.dart', '''
class AppBinding extends WidgetsFlutterBinding {}
''');

    final views = await plan();

    expect(
      (views as RaccoonViewsSkipped).reason,
      contains('binding of its own'),
    );
    expect((views).reason, contains(path.join('lib', 'src', 'binding.dart')));
  });

  test('an app that starts a package\'s binding keeps its main', () async {
    _write(project, 'lib/main.dart', '''
void main() {
  SentryWidgetsFlutterBinding.ensureInitialized();
}
''');

    final views = await plan();

    expect(
      (views as RaccoonViewsSkipped).reason,
      contains('SentryWidgetsFlutterBinding'),
    );
  });

  test('the usual binding and its observers are no binding of the app\'s',
      () async {
    _write(project, 'lib/main.dart', '''
void main() {
  WidgetsFlutterBinding.ensureInitialized();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {}
''');

    expect(await plan(), isA<RaccoonViewsEntry>());
  });

  test('an app in a zone of its own keeps its main', () async {
    _write(project, 'lib/bootstrap.dart', '''
void bootstrap() => runZonedGuarded(() {}, (error, stack) {});
''');

    final views = await plan();

    expect((views as RaccoonViewsSkipped).reason, contains('runZonedGuarded'));
  });

  test('an entry that is the same is not written again', () async {
    await plan();
    final entry = File(path.join(project.path, RaccoonViewsLaunch.entryPath));
    final written = DateTime(2000);
    entry.setLastModifiedSync(written);

    await plan();

    expect(entry.lastModifiedSync(), written);
  });
}

void _write(Directory project, String relative, String source) {
  File(path.join(project.path, relative))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);
}
