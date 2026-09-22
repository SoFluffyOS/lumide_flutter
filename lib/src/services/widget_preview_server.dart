import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef PreviewProcessStarter = Future<Process> Function(
    List<String> command, String directory);

/// One machine-mode server. Concurrent starts share the same process and URL.
class WidgetPreviewServer {
  WidgetPreviewServer({
    PreviewProcessStarter? startProcess,
    this.startupTimeout = const Duration(minutes: 2),
  }) : _startProcess = startProcess ?? _spawn;

  final PreviewProcessStarter _startProcess;
  final Duration startupTimeout;
  Process? _process;
  Future<Process>? _spawning;
  int? _toolPid;
  Future<String>? _starting;
  Future<void>? _stopping;
  Completer<String>? _ready;
  final List<StreamSubscription<String>> _subscriptions = [];
  final List<String> _logs = [];
  int _generation = 0;
  void Function()? onExit;

  static Future<Process> _spawn(List<String> command, String directory) =>
      Process.start(command.first, command.skip(1).toList(),
          workingDirectory: directory, runInShell: Platform.isWindows);

  Future<String> start(List<String> command, String directory) {
    final pending = _starting;
    if (pending != null) return pending;
    final generation = _generation;
    final operation = _start(command, directory, generation);
    _starting = operation;
    return operation;
  }

  Future<String> _start(List<String> command, String directory, int generation) async {
    await _stopping;
    if (generation != _generation) throw StateError('Preview startup cancelled.');
    _logs.clear();
    final ready = Completer<String>();
    _ready = ready;
    // Attach a handler before spawning: stop can cancel startup at any point.
    final url = ready.future.timeout(startupTimeout);
    unawaited(url.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    try {
      final spawning = _startProcess(
          [...command, 'widget-preview', 'start', '--machine', '--web-server'], directory);
      _spawning = spawning;
      final process = await spawning;
      if (generation != _generation) {
        throw StateError('Preview startup cancelled.');
      }
      _spawning = null;
      _process = process;
      for (final stream in [process.stdout, process.stderr]) {
        _subscriptions.add(stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) => _onLine(line, ready),
          onError: (Object error) {
            if (!ready.isCompleted) ready.completeError(error);
          },
        ));
      }
      unawaited(process.exitCode.then((code) {
        if (generation != _generation) return;
        final started = ready.isCompleted;
        if (!started) {
          ready.completeError(StateError('Widget Preview exited ($code). '
              'Use a Flutter SDK with widget-preview support.\n${_logs.join('\n')}'));
        }
        unawaited(stop().catchError((Object _) {}));
        if (started) onExit?.call();
      }));
      return await url;
    } catch (_) {
      if (generation == _generation) await stop();
      rethrow;
    }
  }

  void _onLine(String line, Completer<String> ready) {
    if (_logs.length == 20) _logs.removeAt(0);
    _logs.add(switch (line.length > 500) { true => line.substring(0, 500), false => line });
    final url = widgetPreviewUrl(line);
    if (url != null && !ready.isCompleted) ready.complete(url);
    try {
      final events = jsonDecode(line);
      if (events is! List) return;
      for (final event in events) {
        if (event is! Map || event['event'] != 'widget_preview.initializing') continue;
        final params = event['params'];
        if (params is! Map) continue;
        final value = params['pid'];
        if (value is int && value > 0 && value != pid) _toolPid = value;
      }
    } on FormatException { /* Ordinary log line. */ }
  }

  Future<void> stop() {
    final pending = _stopping;
    if (pending != null) return pending;
    _generation++;
    _starting = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('Preview startup cancelled.'));
    }
    final process = _process;
    final spawning = _spawning;
    final toolPid = _toolPid;
    _spawning = null;
    _toolPid = null;
    _process = null;
    final subscriptions = _subscriptions.toList();
    _subscriptions.clear();
    final stopping = () async {
      await Future.wait(subscriptions.map((s) => s.cancel()));
      Process? child = process;
      if (child == null && spawning != null) {
        try { child = await spawning; } catch (_) { return; }
      }
      if (child != null) {
        if (toolPid != null && toolPid != child.pid) Process.killPid(toolPid);
        await _terminate(child);
      }
    }();
    _stopping = stopping;
    return stopping.whenComplete(() {
      if (identical(_stopping, stopping)) _stopping = null;
    });
  }

  static Future<void> _terminate(Process process) async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
    }
  }
}

/// Flutter machine events are JSON arrays. Never embed an arbitrary log URL.
String? widgetPreviewUrl(String line) {
  try {
    final events = jsonDecode(line);
    if (events is! List) return null;
    for (final event in events) {
      if (event is! Map || event['event'] != 'widget_preview.started') continue;
      final params = event['params'];
      if (params is! Map || params['url'] is! String) continue;
      final uri = Uri.tryParse(params['url'] as String);
      if (uri == null || !const ['http', 'https'].contains(uri.scheme) ||
          !const ['localhost', '127.0.0.1', '::1'].contains(uri.host) ||
          uri.userInfo.isNotEmpty || !uri.hasPort || uri.port == 0) {
        continue;
      }
      return uri.toString();
    }
  } on FormatException { /* Ordinary Flutter log line. */ }
  return null;
}
