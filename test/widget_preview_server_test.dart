import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';

String event(String url) => jsonEncode([{'event': 'widget_preview.started', 'params': {'url': url}}]);

void main() {
  test('only accepts loopback URLs from the started event', () {
    for (final url in ['http://localhost:1234/', 'http://127.0.0.1:1234/', 'http://[::1]:1234/']) {
      expect(widgetPreviewUrl(event(url)), url);
    }
    for (final line in ['invalid json', '{}', '[null, 1]', 'http://localhost:1234/',
      event('https://example.com:443'), event('file:///tmp/preview'), event('http://user@localhost:1234'),
      event('http://localhost:0'), event('http://localhost')]) {
      expect(widgetPreviewUrl(line), isNull);
    }
  });

  test('shares startup, passes SDK args, reuses URL, and can restart after stop', () async {
    final processes = <_Process>[];
    final server = WidgetPreviewServer(startProcess: (command, directory) async {
      expect(command, ['puro', 'flutter', 'widget-preview', 'start', '--machine', '--web-server']);
      expect(directory, '/workspace/example');
      final process = _Process();
      processes.add(process);
      return process;
    });
    addTearDown(server.stop);
    final first = server.start(['puro', 'flutter'], '/workspace/example');
    final second = server.start(['puro', 'flutter'], '/workspace/example');
    await Future<void>.delayed(Duration.zero);
    expect(processes.length, 1);
    processes.single.line('ordinary build output');
    processes.single.line(event('http://localhost:1234/'));
    expect(await first, 'http://localhost:1234/');
    expect(await second, await first);
    expect(await server.start(['puro', 'flutter'], '/workspace/example'), await first);
    await server.stop();
    expect(processes.single.kills, 1);
    final restarted = server.start(['puro', 'flutter'], '/workspace/example');
    await Future<void>.delayed(Duration.zero);
    processes.last.line(event('http://localhost:5678/'));
    expect(await restarted, 'http://localhost:5678/');
    expect(processes.length, 2);
  });

  test('stop during spawn waits for and terminates the late process', () async {
    final spawn = Completer<Process>();
    final server = WidgetPreviewServer(startProcess: (_, __) => spawn.future);
    final opening = server.start(['flutter'], '/project');
    final failed = expectLater(opening, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final stopped = server.stop();
    final process = _Process();
    spawn.complete(process);
    await stopped;
    await failed;
    expect(process.kills, 1);
  });

  test('startup timeout terminates the server and allows retry', () async {
    final processes = <_Process>[];
    final server = WidgetPreviewServer(startupTimeout: const Duration(milliseconds: 20), startProcess: (_, __) async {
      final process = _Process();
      processes.add(process);
      return process;
    });
    addTearDown(server.stop);
    await expectLater(server.start(['flutter'], '/project'), throwsA(isA<TimeoutException>()));
    expect(processes.single.kills, 1);
    final retry = server.start(['flutter'], '/project');
    await Future<void>.delayed(Duration.zero);
    processes.last.line(event('http://localhost:1234/'));
    expect(await retry, 'http://localhost:1234/');
  });

  test('startup exit reports bounded diagnostics and permits retry', () async {
    final process = _Process();
    final server = WidgetPreviewServer(startProcess: (_, __) async => process);
    addTearDown(server.stop);
    final opening = server.start(['flutter'], '/project');
    final failed = expectLater(opening, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('SDK'))));
    await Future<void>.delayed(Duration.zero);
    process.line('Could not find a command named widget-preview.');
    process.exited.complete(64);
    await failed;
  });
}

class _Process implements Process {
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final exited = Completer<int>();
  int kills = 0;
  void line(String line) => out.add(utf8.encode('$line\n'));
  @override
  int get pid => 987654;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!exited.isCompleted) exited.complete(0);
    return true;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
