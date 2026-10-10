import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';

/// A long-running SDK process, started by Lumide (`sdks.spawn`) or locally.
abstract interface class SdkProcess {
  /// Decoded stdout chunks. Single subscription.
  Stream<String> get stdout;

  /// Decoded stderr chunks. Single subscription.
  Stream<String> get stderr;

  Future<int> get exitCode;

  void write(String text);

  /// Stops the process. [force] kills it immediately.
  Future<void> kill({bool force = false});
}

/// An [SdkProcess] started with `dart:io`, for hosts without `sdks.spawn`.
class LocalSdkProcess implements SdkProcess {
  LocalSdkProcess(this._process);

  final Process _process;

  static Future<LocalSdkProcess> start(
    List<String> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    final process = await Process.start(
      command.first,
      command.skip(1).toList(),
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: runInShell,
    );
    return LocalSdkProcess(process);
  }

  @override
  Stream<String> get stdout => _process.stdout.transform(utf8.decoder);

  @override
  Stream<String> get stderr => _process.stderr.transform(utf8.decoder);

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void write(String text) => _process.stdin.write(text);

  @override
  Future<void> kill({bool force = false}) async {
    _process.kill(switch (force) {
      true => ProcessSignal.sigkill,
      false => ProcessSignal.sigterm,
    });
  }
}

/// Routes `shell.onStdout`/`onStderr`/`onExit` to processes started with
/// `sdks.spawn`.
///
/// Output can arrive before `spawn` returns the pid, so while a spawn is in
/// flight, output for unknown pids is held and replayed once claimed.
class HostProcessHub {
  HostProcessHub(this._shell,
      {this.exitGrace = const Duration(milliseconds: 100)});

  static const _maxHeldEvents = 1000;

  final LumideShell _shell;

  /// How long output is still accepted after the exit notification, since
  /// Lumide can report the exit before the last output chunk.
  final Duration exitGrace;

  final Map<int, HostSdkProcess> _processes = {};
  final Map<int, List<_HostEvent>> _held = {};
  final List<LumideDisposable> _listeners = [];
  int _spawnsInFlight = 0;
  int _heldEventCount = 0;

  /// Runs [spawn] and returns the process for the pid it resolves to.
  Future<HostSdkProcess> spawn(Future<int> Function() spawn) async {
    _listen();
    _spawnsInFlight++;
    try {
      final pid = await spawn();
      final process = HostSdkProcess._(pid, _shell, exitGrace);
      _processes[pid] = process;
      for (final event in _held.remove(pid) ?? const <_HostEvent>[]) {
        _dispatch(process, event);
      }
      return process;
    } finally {
      _spawnsInFlight--;
      if (_spawnsInFlight == 0) {
        _held.clear();
        _heldEventCount = 0;
      }
    }
  }

  void dispose() {
    for (final listener in _listeners) {
      listener.dispose();
    }
    _listeners.clear();
    _held.clear();
    for (final process in _processes.values.toList()) {
      process._finish(-1);
    }
    _processes.clear();
  }

  void _listen() {
    if (_listeners.isNotEmpty) return;
    _listeners
      ..add(
          _shell.onStdout((pid, data) => _route(pid, _HostEvent.stdout(data))))
      ..add(
          _shell.onStderr((pid, data) => _route(pid, _HostEvent.stderr(data))))
      ..add(_shell.onExit((pid, code) => _route(pid, _HostEvent.exit(code))));
  }

  void _route(int pid, _HostEvent event) {
    if (_processes[pid] case final process?) {
      _dispatch(process, event);
      return;
    }
    final canHold = _spawnsInFlight > 0 && _heldEventCount < _maxHeldEvents;
    if (!canHold) return;
    _held.putIfAbsent(pid, () => []).add(event);
    _heldEventCount++;
  }

  void _dispatch(HostSdkProcess process, _HostEvent event) {
    switch (event) {
      case _HostEvent(kind: _HostEventKind.stdout, :final data):
        process._addStdout(data);
      case _HostEvent(kind: _HostEventKind.stderr, :final data):
        process._addStderr(data);
      case _HostEvent(kind: _HostEventKind.exit, :final exitCode):
        unawaited(
          process._exit(exitCode).whenComplete(
                () => _processes.remove(process.pid),
              ),
        );
    }
  }
}

/// A process started by Lumide with `sdks.spawn`.
class HostSdkProcess implements SdkProcess {
  HostSdkProcess._(this.pid, this._shell, this._exitGrace);

  final int pid;
  final LumideShell _shell;
  final Duration _exitGrace;
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();
  final _exitCode = Completer<int>();

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Stream<String> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(String text) {
    if (_exitCode.isCompleted) return;
    unawaited(_shell.writeStdin(pid, text).catchError((Object _) {}));
  }

  @override
  Future<void> kill({bool force = false}) async {
    if (_exitCode.isCompleted) return;
    try {
      await _shell.kill(
        pid,
        signal: switch (force) {
          true => LumideProcessSignal.kill,
          false => LumideProcessSignal.terminate,
        },
      );
    } catch (_) {
      // The process already exited or the host stopped tracking it.
    }
  }

  void _addStdout(String data) {
    if (_stdout.isClosed) return;
    _stdout.add(data);
  }

  void _addStderr(String data) {
    if (_stderr.isClosed) return;
    _stderr.add(data);
  }

  Future<void> _exit(int code) async {
    if (_exitCode.isCompleted) return;
    await Future<void>.delayed(_exitGrace);
    _finish(code);
  }

  void _finish(int code) {
    if (_exitCode.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(code);
  }
}

enum _HostEventKind { stdout, stderr, exit }

class _HostEvent {
  const _HostEvent.stdout(this.data)
      : kind = _HostEventKind.stdout,
        exitCode = 0;

  const _HostEvent.stderr(this.data)
      : kind = _HostEventKind.stderr,
        exitCode = 0;

  const _HostEvent.exit(this.exitCode)
      : kind = _HostEventKind.exit,
        data = '';

  final _HostEventKind kind;
  final String data;
  final int exitCode;
}
