import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/daemon_service.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('retries after no workspace and restarts with a fresh process',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'lumide-flutter-daemon-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = await _writeFakeDaemon(directory);
    final counterPath = path.join(directory.path, '.daemon-launch-count');
    final context = _FakeContext();
    final projectService = _RetryingProjectService(
      context,
      directory.path,
    );
    final sdkManager = _FakeSdkManager(
      context,
      [Platform.resolvedExecutable, script.path, counterPath],
    );
    final logs = <String>[];
    final daemon = DaemonService(
      context,
      projectService,
      sdkManager,
      LogService(logs.add),
    );
    addTearDown(daemon.dispose);

    await daemon.start();
    expect(daemon.isRunning, isFalse);

    await daemon.start();
    expect(daemon.isRunning, isTrue);
    expect(await daemon.getDevices(), isEmpty);
    expect(await _readCount(counterPath), 1);

    await daemon.restart();
    expect(daemon.isRunning, isTrue);
    expect(await daemon.getDevices(), isEmpty);
    expect(await _readCount(counterPath), 2);

    expect(logs, contains(contains('Workspace is not open yet')));
  });
}

Future<File> _writeFakeDaemon(Directory directory) async {
  final script = File(path.join(directory.path, 'fake_daemon.dart'));
  await script.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final counter = File(arguments.first);
  final previous = counter.existsSync()
      ? int.tryParse(counter.readAsStringSync()) ?? 0
      : 0;
  counter.writeAsStringSync((previous + 1).toString());
  stdout.writeln(jsonEncode([
    {'event': 'daemon.connected', 'params': <String, Object?>{}},
  ]));

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final messages = jsonDecode(line) as List;
    final request = messages.first as Map<String, dynamic>;
    final id = request['id'];
    final method = request['method'];
    final result = method == 'device.getDevices' ? const [] : null;
    stdout.writeln(jsonEncode([
      {'id': id, 'result': result},
    ]));
    if (method == 'daemon.shutdown') return;
  }
}
''');
  return script;
}

Future<int> _readCount(String counterPath) async {
  return int.parse(await File(counterPath).readAsString());
}

class _FakeContext implements LumideContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RetryingProjectService extends ProjectService {
  _RetryingProjectService(super.context, this.rootPath);

  final String rootPath;
  var attempts = 0;

  @override
  Future<String> getProjectRoot([String? uri]) async {
    attempts++;
    if (attempts == 1) throw StateError('Workspace is not open yet');
    return rootPath;
  }
}

class _FakeSdkManager extends SdkManager {
  _FakeSdkManager(super.context, this.command);

  final List<String> command;

  @override
  Future<List<String>> getFlutterCommand(String projectRoot) async => command;
}
