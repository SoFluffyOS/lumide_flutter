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

  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  Stream<Map<String, dynamic>> get onDeviceAdded =>
      _deviceAddedController.stream;
  Stream<Map<String, dynamic>> get onDeviceRemoved =>
      _deviceRemovedController.stream;
  Stream<Map<String, dynamic>> get onDaemonConnected =>
      _daemonConnectedController.stream;

  bool _isStarting = false;
  bool get isRunning => _process != null;

  DaemonService(
      this.context, this.projectService, this.sdkManager, this.logService);

  Future<void> start() async {
    if (_process != null || _isStarting) return;
    _isStarting = true;

    try {
      final root = await projectService.getProjectRoot();
      final flutterCmd = await sdkManager.getFlutterCommand(root);
      final executable = flutterCmd.first;
      final args = [...flutterCmd.sublist(1), 'daemon'];

      _process = await Process.start(
        executable,
        args,
        workingDirectory: root,
      );

      final proc = _process!;

      _stdoutSub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine);

      _stderrSub = proc.stderr.transform(utf8.decoder).listen((data) {
        logService.warn('Daemon stderr: $data');
      });

      // Timeout for ready state to avoid hanging if daemon fails silently
      Future.delayed(const Duration(seconds: 15), () {
        if (!_readyCompleter.isCompleted) {
          _readyCompleter.completeError(
              Exception('Daemon failed to start within 15 seconds'));
        }
      });

      unawaited(proc.exitCode.then((code) {
        _process = null;
        _failPendingRequests('Daemon process exited with code $code');
      }));
    } catch (e) {
      logService.error('Failed to start flutter daemon', e);
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.completeError(e);
      }
    } finally {
      _isStarting = false;
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
          _daemonConnectedController.add(params);
          break;
        case 'device.added':
          _deviceAddedController.add(params);
          break;
        case 'device.removed':
          _deviceRemovedController.add(params);
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
    await ready;

    if (_process == null) {
      return Future.error(Exception('Flutter daemon is not running'));
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
    _process!.stdin.writeln(jsonEncode(payload));

    return completer.future;
  }

  void _failPendingRequests(String error) {
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.completeError(Exception(error));
    }
    for (final completer in _pendingRequests.values) {
      completer.completeError(Exception(error));
    }
    _pendingRequests.clear();
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
    _failPendingRequests('Daemon service is disposing');
    if (_process != null) {
      await _sendRequest('daemon.shutdown').catchError((_) {});
      _process?.kill();
      _process = null;
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _deviceAddedController.close();
    await _deviceRemovedController.close();
    await _daemonConnectedController.close();
  }
}
