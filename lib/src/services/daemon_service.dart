import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';

class DaemonService {
  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final LogService logService;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  int _requestId = 0;
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  final _deviceAddedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _deviceRemovedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _daemonConnectedController =
      StreamController<Map<String, dynamic>>.broadcast();

  Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  Stream<Map<String, dynamic>> get onDeviceAdded =>
      _deviceAddedController.stream;
  Stream<Map<String, dynamic>> get onDeviceRemoved =>
      _deviceRemovedController.stream;
  Stream<Map<String, dynamic>> get onDaemonConnected =>
      _daemonConnectedController.stream;

  Future<void>? _startInFlight;
  Timer? _startupTimer;
  bool _disposed = false;
  bool get isRunning => _process != null;

  DaemonService(
      this.context, this.projectService, this.sdkManager, this.logService);

  Future<void> start() {
    if (_disposed) {
      return Future.error(StateError('Daemon service is disposed'));
    }
    if (_process != null) return _waitUntilReady(_readyCompleter);
    final existing = _startInFlight;
    if (existing != null) return existing;

    late final Future<void> startFuture;
    startFuture = _start().whenComplete(() {
      if (identical(_startInFlight, startFuture)) {
        _startInFlight = null;
      }
    });
    _startInFlight = startFuture;
    return startFuture;
  }

  Future<void> _start() async {
    if (_readyCompleter.isCompleted) {
      _readyCompleter = Completer<void>();
    }
    final readyCompleter = _readyCompleter;

    try {
      final root = await projectService.getProjectRoot();
      final flutterCmd = await sdkManager.getFlutterCommand(root);
      final executable = flutterCmd.first;
      final args = [...flutterCmd.sublist(1), 'daemon'];
      final process = await Process.start(
        executable,
        args,
        workingDirectory: root,
      );
      if (_disposed) {
        process.kill();
        return;
      }
      _process = process;

      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine);
      _stderrSub = process.stderr.transform(utf8.decoder).listen((data) {
        logService.warn('Daemon stderr: $data');
      });

      _startupTimer?.cancel();
      _startupTimer = Timer(const Duration(seconds: 15), () {
        if (identical(_process, process) && !readyCompleter.isCompleted) {
          _completeReadyError(
            readyCompleter,
            Exception('Daemon failed to start within 15 seconds'),
          );
        }
      });

      unawaited(process.exitCode.then((code) {
        if (!identical(_process, process)) return;
        _process = null;
        _startupTimer?.cancel();
        _startupTimer = null;
        _failPendingRequests('Daemon process exited with code $code');
      }));

      await readyCompleter.future;
    } catch (error, stackTrace) {
      logService.error('Flutter daemon failed to become ready', error);
      if (!readyCompleter.isCompleted) {
        _completeReadyError(readyCompleter, error, stackTrace);
      }
      if (_process != null) {
        await _stopProcess('Flutter daemon failed to start');
      }
    }
  }

  Future<void> _waitUntilReady(Completer<void> completer) async {
    try {
      await completer.future;
    } catch (error) {
      logService.error('Flutter daemon failed to become ready', error);
    }
  }

  void _handleStdoutLine(String line) {
    if (line.isEmpty) return;

    if (!line.startsWith('[')) {
      // Not a JSON-RPC message, could be regular output
      return;
    }

    try {
      final decoded = jsonDecode(line);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            _handleMessage(item);
          }
        }
      }
    } on FormatException catch (e) {
      logService.error('Daemon output format exception\nData: $line', e);
    } catch (e) {
      logService.error('Daemon output parsing error\nData: $line', e);
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    if (message.containsKey('id') &&
        !message.containsKey('method') &&
        !message.containsKey('event')) {
      // Response to a request
      final id = message['id'] as int;
      final completer = _pendingRequests.remove(id);
      if (completer != null) {
        if (message.containsKey('error')) {
          completer.completeError(Exception(message['error']));
        } else {
          completer.complete(message['result']);
        }
      }
    } else if (message.containsKey('event')) {
      // Event
      final event = message['event'] as String;
      final params = message['params'] as Map<String, dynamic>? ?? {};

      switch (event) {
        case 'daemon.connected':
          if (!_readyCompleter.isCompleted) {
            _readyCompleter.complete();
          }
          if (!_daemonConnectedController.isClosed) {
            _daemonConnectedController.add(params);
          }
          break;
        case 'device.added':
          if (!_deviceAddedController.isClosed) {
            _deviceAddedController.add(params);
          }
          break;
        case 'device.removed':
          if (!_deviceRemovedController.isClosed) {
            _deviceRemovedController.add(params);
          }
          break;
        case 'daemon.logMessage':
          // Optional: handle log messages
          logService.info('Daemon log: $params');
          break;
        default:
          logService.warn('Daemon unhandled event: $event');
          break;
      }
    } else {
      logService.warn('Daemon unhandled message: $message');
    }
  }

  Future<dynamic> _sendRequest(String method,
      [Map<String, dynamic>? params]) async {
    if (_process == null) await start();
    final process = _process;
    if (process == null) {
      throw Exception('Flutter daemon is not running');
    }
    await _readyCompleter.future;
    if (!identical(_process, process)) {
      throw Exception('Flutter daemon changed while sending a request');
    }

    final id = ++_requestId;
    final completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    final request = <String, dynamic>{
      'id': id,
      'method': method,
    };
    if (params != null) {
      request['params'] = params;
    }

    final payload = [request];
    process.stdin.writeln(jsonEncode(payload));

    return completer.future;
  }

  void _failPendingRequests(String error) {
    if (!_readyCompleter.isCompleted) {
      _completeReadyError(_readyCompleter, Exception(error));
    }
    for (final completer in _pendingRequests.values) {
      completer.completeError(Exception(error));
    }
    _pendingRequests.clear();
  }

  void _completeReadyError(
    Completer<void> completer,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    if (completer.isCompleted) return;
    final future = completer.future;
    completer.completeError(error, stackTrace ?? StackTrace.current);
    unawaited(future.catchError((Object _, StackTrace __) {}));
  }

  Future<void> restart() async {
    if (_disposed) return;
    final starting = _startInFlight;
    if (starting != null) await starting;
    await _stopProcess('Flutter daemon is restarting');
    if (_disposed) return;
    _readyCompleter = Completer<void>();
    await start();
  }

  Future<void> _stopProcess(String reason) async {
    final process = _process;
    _process = null;
    _startupTimer?.cancel();
    _startupTimer = null;

    if (process != null) {
      try {
        final id = ++_requestId;
        final completer = Completer<dynamic>();
        _pendingRequests[id] = completer;
        process.stdin.writeln(
          jsonEncode([
            {'id': id, 'method': 'daemon.shutdown'},
          ]),
        );
        await completer.future.timeout(const Duration(seconds: 1));
      } catch (_) {
        // Continue with process termination below.
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } catch (_) {
          // The OS owns the remaining cleanup if it cannot be joined.
        }
      }
    }

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _failPendingRequests(reason);
  }

  // --- Daemon API ---

  Future<List<Map<String, dynamic>>> getDevices() async {
    final result = await _sendRequest('device.getDevices');
    if (result is List) {
      return result.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<void> enableDevicePolling() async {
    await _sendRequest('device.enable');
  }

  Future<void> disableDevicePolling() async {
    await _sendRequest('device.disable');
  }

  Future<Map<String, dynamic>> serveDevTools() async {
    final result = await _sendRequest('devtools.serve');
    if (result is Map<String, dynamic>) {
      return result;
    }
    throw Exception('Invalid result from devtools.serve');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stopProcess('Daemon service is disposing');
    await _deviceAddedController.close();
    await _deviceRemovedController.close();
    await _daemonConnectedController.close();
  }
}
