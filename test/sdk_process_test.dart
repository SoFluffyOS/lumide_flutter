import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
import 'package:test/test.dart';

void main() {
  late _FakeShell shell;
  late HostProcessHub hub;

  setUp(() {
    shell = _FakeShell();
    hub = HostProcessHub(shell, exitGrace: Duration.zero);
  });

  tearDown(() => hub.dispose());

  test('replays output that arrives before spawn returns the pid', () async {
    final pid = Completer<int>();
    final spawning = hub.spawn(() => pid.future);
    shell.stdout(7, 'early\n');
    pid.complete(7);
    final process = await spawning;

    shell.stdout(7, 'late\n');
    shell.exit(7, 0);

    expect(await process.stdout.join(), 'early\nlate\n');
    expect(await process.exitCode, 0);
  });

  test('ignores output for other pids', () async {
    final process = await hub.spawn(() async => 1);
    shell.stdout(2, 'other');
    shell.stderr(1, 'mine');
    shell.exit(1, 3);

    expect(await process.stderr.join(), 'mine');
    expect(await process.stdout.join(), '');
    expect(await process.exitCode, 3);
  });

  test('writes stdin and kills through the shell', () async {
    final process = await hub.spawn(() async => 5);
    process.write('hello\n');
    await process.kill();
    await process.kill(force: true);

    expect(shell.writes, [(5, 'hello\n')]);
    expect(shell.kills, [
      (5, LumideProcessSignal.terminate),
      (5, LumideProcessSignal.kill),
    ]);
  });

  test('ends running processes on dispose', () async {
    final process = await hub.spawn(() async => 9);
    hub.dispose();
    expect(await process.exitCode, -1);
  });
}

class _FakeShell implements LumideShell {
  final _stdout = <void Function(int, String)>[];
  final _stderr = <void Function(int, String)>[];
  final _exit = <void Function(int, int)>[];
  final writes = <(int, String)>[];
  final kills = <(int, LumideProcessSignal?)>[];

  void stdout(int pid, String data) {
    for (final callback in _stdout) {
      callback(pid, data);
    }
  }

  void stderr(int pid, String data) {
    for (final callback in _stderr) {
      callback(pid, data);
    }
  }

  void exit(int pid, int code) {
    for (final callback in _exit) {
      callback(pid, code);
    }
  }

  @override
  LumideDisposable onStdout(void Function(int pid, String data) callback) {
    _stdout.add(callback);
    return LumideDisposable(() => _stdout.remove(callback));
  }

  @override
  LumideDisposable onStderr(void Function(int pid, String data) callback) {
    _stderr.add(callback);
    return LumideDisposable(() => _stderr.remove(callback));
  }

  @override
  LumideDisposable onExit(void Function(int pid, int exitCode) callback) {
    _exit.add(callback);
    return LumideDisposable(() => _exit.remove(callback));
  }

  @override
  Future<void> writeStdin(int pid, String text) async =>
      writes.add((pid, text));

  @override
  Future<bool> kill(int pid, {LumideProcessSignal? signal}) async {
    kills.add((pid, signal));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
