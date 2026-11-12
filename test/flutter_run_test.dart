import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';

void main() {
  group('FlutterRun', () {
    test('a restart answers with the errors logged until the daemon answers',
        () async {
      final process = _Process();
      final run = _run(process)..appId = 'app-1';

      final result = run.restartApp(fullRestart: false);
      final request = process.lastRequest;
      run.noteError("lib/main.dart:4:3: Error: Expected ';' after this.");
      run.handleResponse({
        'id': request['id'],
        'result': {'code': 1, 'message': 'Reload rejected'},
      });
      run.noteError('Logged after the answer');

      final outcome = await result;
      expect(request['method'], 'app.restart');
      expect(request['params'], {
        'appId': 'app-1',
        'fullRestart': false,
        'pause': false,
      });
      expect(outcome.isSuccess, isFalse);
      expect(outcome.message, 'Reload rejected');
      expect(outcome.errors, [
        "lib/main.dart:4:3: Error: Expected ';' after this.",
      ]);
    });

    test('errors logged outside a restart are not kept', () async {
      final process = _Process();
      final run = _run(process)..appId = 'app-1';
      run.noteError('Before');

      final result = run.restartApp(fullRestart: true);
      run.handleResponse({
        'id': process.lastRequest['id'],
        'result': {'code': 0, 'message': 'Restarted'},
      });

      final outcome = await result;
      expect(outcome.isSuccess, isTrue);
      expect(outcome.errors, isEmpty);
    });

    test('requests before the app started are cancelled unsent', () async {
      final process = _Process();
      final run = _run(process);

      final result = await run.request('app.stop');

      expect(result.cancelled, isTrue);
      expect(process.written, isEmpty);
    });

    test('dispose answers waiting requests as cancelled', () async {
      final process = _Process();
      final run = _run(process)..appId = 'app-1';

      final result = run.restartApp(fullRestart: false);
      await run.dispose();

      expect((await result).cancelled, isTrue);
    });

    test('quiet reloads are reported as quiet', () async {
      final process = _Process();
      final reported = <bool>[];
      final run = FlutterRun(
        kind: LumideLaunchKind.run,
        configurationId: 'main',
        process: process,
        onRestartResult: (result, {required fullRestart, required quiet}) {
          reported.add(quiet);
        },
      )..appId = 'app-1';

      final quiet = run.reloads.reload(quiet: true);
      await pumpEventQueue();
      run.handleResponse({'id': process.lastRequest['id'], 'result': null});
      await quiet;
      final told = run.reloads.reload();
      await pumpEventQueue();
      run.handleResponse({'id': process.lastRequest['id'], 'result': null});
      await told;

      expect(reported, [true, false]);
    });

    test('events name the launch, and an end has no device', () {
      final run = _run(
        _Process(),
        folder: '/work/app',
        deviceId: 'macos',
      );

      final attached = run.event(vmServiceUri: 'ws://127.0.0.1:1/ws');
      final ended = run.event(exitCode: 0);

      expect(attached.toJson(), {
        'providerId': 'flutter',
        'kind': 'debug',
        'configurationId': 'main',
        'workspaceFolder': '/work/app',
        'deviceId': 'macos',
        'vmServiceUri': 'ws://127.0.0.1:1/ws',
      });
      expect(ended.deviceId, isNull);
      expect(ended.exitCode, 0);
    });
  });

  group('FlutterRuns', () {
    test('finds a launch by configuration, kind and folder', () {
      final runs = FlutterRuns();
      final app = _run(_Process(), folder: '/work/app');
      final other = _run(_Process(), folder: '/work/other');
      runs
        ..add(app)
        ..add(other);

      expect(
        runs.find(
          kind: LumideLaunchKind.debug,
          configurationId: 'main',
          workspaceFolder: '/work/app/',
        ),
        same(app),
      );
      expect(
        runs.find(kind: LumideLaunchKind.debug, configurationId: 'main'),
        same(other),
      );
      expect(
        runs.find(kind: LumideLaunchKind.run, configurationId: 'main'),
        isNull,
      );
      expect(
        runs.find(kind: LumideLaunchKind.debug, configurationId: 'other'),
        isNull,
      );
    });

    test('lists the runs whose app started, oldest first', () {
      final runs = FlutterRuns();
      final starting = _run(_Process());
      final first = _run(_Process())..appId = 'a';
      final second = _run(_Process())..appId = 'b';
      runs
        ..add(starting)
        ..add(first)
        ..add(second);

      runs.remove(starting);

      expect(runs.started, [first, second]);
      expect(runs.first, same(first));
    });
  });
}

FlutterRun _run(_Process process, {String? folder, String? deviceId}) {
  return FlutterRun(
    kind: LumideLaunchKind.debug,
    configurationId: 'main',
    workspaceFolder: folder,
    deviceId: deviceId,
    process: process,
  );
}

class _Process implements SdkProcess {
  final written = <String>[];

  Map<String, dynamic> get lastRequest {
    final payload = jsonDecode(written.last) as List;
    return payload.single as Map<String, dynamic>;
  }

  @override
  Stream<String> get stdout => const Stream.empty();

  @override
  Stream<String> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  void write(String text) => written.add(text);

  @override
  Future<void> kill({bool force = false}) async {}
}
