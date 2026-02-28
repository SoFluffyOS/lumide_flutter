import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/device_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class RunService {
  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final DeviceService deviceService;

  LumideOutputChannel? _runChannel;
  LumideOutputChannel? _buildChannel;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  bool _isConnectingToVmService = false;

  VmService? _vmService;
  StreamSubscription? _vmStdoutSub;
  StreamSubscription? _vmStderrSub;
  StreamSubscription? _vmLoggingSub;
  String? _devToolsUrl;

  String? _activeAppId;
  int _requestId = 0;

  RunService(
      this.context, this.projectService, this.sdkManager, this.deviceService);

  Future<void> init() async {
    final logLimit =
        await context.workspace.getConfiguration(confLogEntryLimit) as int? ??
            defaultLogEntryLimit;

    _runChannel = await context.window
        .createOutputChannel(channelFlutter, maxEntries: logLimit);
    _buildChannel = await context.window
        .createOutputChannel(channelBuildOutput, maxEntries: logLimit);

    await _showRunControls(isRunning: false);

    context.workspace.onDidSaveTextDocument((uri) async {
      if (_isRunning && _activeAppId != null && uri.endsWith('.dart')) {
        final shouldReload = await context.workspace
                .getConfiguration(confHotReloadOnSave) as bool? ??
            defaultHotReloadOnSave;

        if (shouldReload) {
          await hotReload();
        }
      }
    });
  }

  Future<void> _showRunControls({required bool isRunning}) async {
    if (isRunning) {
      await context.toolbar.unregisterItem(cmdFlutterRun);

      await context.toolbar.registerItem(
        id: cmdFlutterHotReload,
        icon: iconZap,
        tooltip: 'Hot Reload',
        alignment: ToolbarItemAlignment.right,
        priority: 100,
      );
      await context.toolbar.registerItem(
        id: cmdFlutterHotRestart,
        icon: iconRefreshCw,
        tooltip: 'Hot Restart',
        alignment: ToolbarItemAlignment.right,
        priority: 99,
      );
      await context.toolbar.registerItem(
        id: cmdFlutterStop,
        icon: iconStop,
        tooltip: 'Stop App',
        alignment: ToolbarItemAlignment.right,
        priority: 98,
      );
    } else {
      await context.toolbar.unregisterItem(cmdFlutterStop);
      await context.toolbar.unregisterItem(cmdFlutterHotReload);
      await context.toolbar.unregisterItem(cmdFlutterHotRestart);

      await context.toolbar.registerItem(
        id: cmdFlutterRun,
        icon: iconPlay,
        tooltip: 'Run Flutter App',
        alignment: ToolbarItemAlignment.right,
        priority: 100,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------

  Future<void> run() async {
    if (_isRunning) {
      await context.window.showMessage(
          'A Flutter app is already running. Stop it before starting a new one.',
          type: MessageType.warning);
      return;
    }

    final root = await projectService.getProjectRoot();
    if (root == null) {
      await context.window.showMessage(
          'No Flutter project found. Open a project with a pubspec.yaml first.',
          type: MessageType.error);
      return;
    }

    final deviceId = deviceService.selectedDeviceId;
    if (deviceId == null) {
      await context.window.showMessage(
          'No device selected. Use the device picker to choose one.',
          type: MessageType.error);
      return;
    }

    final flutterCmd = await sdkManager.getFlutterCommand(root);
    final args = ['run', '--machine', '-d', deviceId];

    try {
      await context.window.showMessage('Running on $deviceId');
      await _buildChannel?.show();

      final executable = flutterCmd.first;
      final finalArgs = [...flutterCmd.sublist(1), ...args];

      await _logInfo('Launching $executable ${finalArgs.join(' ')}...',
          channel: _buildChannel);

      _activeAppId = null;
      _requestId = 0;
      _devToolsUrl = null;

      _process = await Process.start(
        executable,
        finalArgs,
        workingDirectory: root,
      );

      _isRunning = true;
      await _showRunControls(isRunning: true);

      if (_process case final proc?) {
        _stdoutSub = proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_handleStdoutLine);

        _stderrSub = proc.stderr.transform(utf8.decoder).listen((data) {
          _buildChannel?.append('[ERR] $data');
        });

        unawaited(proc.exitCode.then((code) async {
          _isRunning = false;
          _process = null;
          _activeAppId = null;
          _devToolsUrl = null;
          await _stdoutSub?.cancel();
          _stdoutSub = null;
          await _stderrSub?.cancel();
          _stderrSub = null;
          await _disconnectVmService();
          await _showRunControls(isRunning: false);
          await _logInfo('Process exited with code $code.',
              channel: _buildChannel);
        }));
      }
    } catch (err) {
      await context.window.showMessage(
        'Failed to launch: $err',
        type: MessageType.error,
      );
      await _logError('Run error: $err', err, _buildChannel);
      _isRunning = false;
      _process = null;
      _activeAppId = null;
      await _showRunControls(isRunning: false);
    }
  }

  // ---------------------------------------------------------------------------
  // Machine protocol event handling
  // ---------------------------------------------------------------------------

  void _handleStdoutLine(String line) {
    if (line.isEmpty) return;

    // The --machine protocol emits JSON arrays on stdout, one per line.
    // Non-JSON lines (e.g. Gradle output) are forwarded to the build channel.
    if (!line.startsWith('[')) {
      _buildChannel?.append(line);
      return;
    }

    try {
      final decoded = jsonDecode(line);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            _handleMachineEvent(item);
          }
        }
      }
    } on FormatException {
      _buildChannel?.append(line);
    }
  }

  void _handleMachineEvent(Map<String, dynamic> event) {
    final eventName = event['event'] as String?;
    final params = event['params'] as Map<String, dynamic>? ?? {};

    switch (eventName) {
      case 'app.start':
        _activeAppId = params['appId'] as String?;
        _logInfo('App started (appId: $_activeAppId)', channel: _buildChannel);

      case 'app.debugPort':
        final wsUri = params['wsUri'] as String?;
        if (wsUri != null) {
          _connectToVmService(wsUri);
        }
        final baseUri = params['baseUri'] as String?;
        if (baseUri != null) {
          _devToolsUrl = baseUri;
        }

      case 'app.started':
        _logInfo('App is running.', channel: _buildChannel);

      case 'app.log':
        final log = params['log'] as String? ?? '';
        if (log.isNotEmpty) {
          _buildChannel?.append(log);
        }

      case 'app.progress':
        final message = params['message'] as String?;
        final finished = params['finished'] as bool? ?? false;
        if (message != null && !finished) {
          _buildChannel?.append(message);
        }

      case 'app.stop':
        _logInfo('App stopped.', channel: _buildChannel);
        _activeAppId = null;

      case 'daemon.logMessage':
        final log = params['log'] as String? ?? '';
        if (log.isNotEmpty) {
          _buildChannel?.append(log);
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Machine protocol command dispatch
  // ---------------------------------------------------------------------------

  void _sendMachineCommand(String method, [Map<String, dynamic>? extraParams]) {
    if (_process == null || _activeAppId == null) return;

    final params = <String, dynamic>{'appId': _activeAppId!};
    if (extraParams != null) {
      params.addAll(extraParams);
    }

    final payload = [
      {'id': ++_requestId, 'method': method, 'params': params}
    ];
    _process!.stdin.writeln(jsonEncode(payload));
  }

  // ---------------------------------------------------------------------------
  // VM Service
  // ---------------------------------------------------------------------------

  Future<void> _connectToVmService(String wsUri) async {
    if (_vmService != null || _isConnectingToVmService) return;
    _isConnectingToVmService = true;

    try {
      await _runChannel?.show();
      await _logInfo('Connecting to VM Service at $wsUri...');

      final vmService = await vmServiceConnectUri(wsUri);
      _vmService = vmService;

      if (_vmService case final service?) {
        await service.streamListen(EventStreams.kStdout);
        await service.streamListen(EventStreams.kStderr);
        await service.streamListen(EventStreams.kLogging);

        _vmStdoutSub = service.onStdoutEvent.listen((event) {
          if (event.kind == EventKind.kWriteEvent && event.bytes != null) {
            _runChannel?.append(utf8.decode(base64Decode(event.bytes!)));
          }
        });

        _vmStderrSub = service.onStderrEvent.listen((event) {
          if (event.kind == EventKind.kWriteEvent && event.bytes != null) {
            _runChannel?.append(utf8.decode(base64Decode(event.bytes!)));
          }
        });

        _vmLoggingSub = service.onLoggingEvent.listen((event) async {
          final logRecord = event.logRecord;
          if (logRecord == null) return;

          final level = logRecord.level != null
              ? _getLogLevelName(logRecord.level!)
              : 'LOG';
          final message = logRecord.message?.valueAsString ?? '';

          final isolateId = event.isolate?.id;
          final error = await _getStringValue(logRecord.error, isolateId);
          final stack = await _getStringValue(logRecord.stackTrace, isolateId);

          final finalLevel =
              (error != null && error.isNotEmpty) ? 'ERROR' : level;

          final record = LumideLogRecord(
            level: finalLevel,
            message: message,
            name: logRecord.loggerName?.valueAsString,
            error: error,
            stackTrace: stack,
            time: logRecord.time != null
                ? DateTime.fromMillisecondsSinceEpoch(logRecord.time!)
                : null,
          );

          unawaited(_runChannel?.appendLog(record));
        });

        await _logInfo('Connected to VM Service. Logs streaming...');
      }
    } catch (e) {
      await _logError('Failed to connect to VM Service', e);
    } finally {
      _isConnectingToVmService = false;
    }
  }

  String _getLogLevelName(int level) {
    if (level >= 1000) return 'ERROR';
    if (level >= 900) return 'WARN';
    if (level >= 800) return 'INFO';
    if (level >= 700) return 'CONFIG';
    if (level >= 500) return 'FINE';
    return 'DEBUG';
  }

  Future<String?> _getStringValue(InstanceRef? ref, String? isolateId) async {
    if (ref == null) return null;
    if (ref.kind == InstanceKind.kNull) return null;
    if (ref.valueAsString == 'null') return null;
    if (ref.valueAsString != null) return ref.valueAsString;

    if (_vmService != null && ref.id != null && isolateId != null) {
      try {
        final result = await _vmService!.invoke(
          isolateId,
          ref.id!,
          'toString',
          [],
          disableBreakpoints: true,
        );
        if (result is InstanceRef) {
          return result.valueAsString;
        }
      } catch (e) {
        return 'Instance of ${ref.classRef?.name} (Error: $e)';
      }
    }
    return 'Instance of ${ref.classRef?.name}';
  }

  Future<void> _disconnectVmService() async {
    await _vmStdoutSub?.cancel();
    _vmStdoutSub = null;
    await _vmStderrSub?.cancel();
    _vmStderrSub = null;
    await _vmLoggingSub?.cancel();
    _vmLoggingSub = null;
    await _vmService?.dispose();
    _vmService = null;
  }

  // ---------------------------------------------------------------------------
  // Hot Reload / Restart / Stop
  // ---------------------------------------------------------------------------

  Future<void> hotReload() async {
    if (!_isRunning || _activeAppId == null) return;
    _sendMachineCommand('app.restart', {'fullRestart': false, 'pause': false});
    await _logInfo('Hot Reload request sent.');
  }

  Future<void> hotRestart() async {
    if (!_isRunning || _activeAppId == null) return;

    final shouldClear = await context.workspace
            .getConfiguration(confClearLogOnHotRestart) as bool? ??
        defaultClearLogOnHotRestart;

    if (shouldClear) {
      await _runChannel?.clear();
    }

    _sendMachineCommand('app.restart', {'fullRestart': true, 'pause': false});
    await _logInfo('Hot Restart request sent.');
  }

  Future<void> openDevTools() async {
    if (!_isRunning) return;

    if (_devToolsUrl != null) {
      await context.window.showMessage('Opening DevTools in browser');
      await context.window.openUrl(_devToolsUrl!);
      return;
    }

    _sendMachineCommand('app.callServiceExtension',
        {'methodName': 'ext.flutter.activeDevToolsServerAddress'});
    await context.window.showMessage(
      'DevTools URL not available yet. Try again shortly.',
    );
  }

  Future<void> openDevToolsInWebview() async {
    if (!_isRunning) return;

    if (_devToolsUrl != null) {
      await context.window.createWebviewPanel(
        'flutter.devtools',
        'Flutter DevTools',
        options: {'url': _devToolsUrl},
      );
      return;
    }

    await context.window.showMessage(
      'DevTools URL not ready yet. Try again shortly.',
    );
  }

  Future<void> stop() async {
    if (!_isRunning || _process == null) return;

    await context.window.showMessage('Stopping Flutter app');

    if (_activeAppId != null) {
      _sendMachineCommand('app.stop');
    }

    if (_process case final proc?) {
      await proc.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }

    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;

    _isRunning = false;
    _process = null;
    _activeAppId = null;
    _devToolsUrl = null;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> dispose() async {
    await stop();
    await _disconnectVmService();
    await _runChannel?.dispose();
    await _buildChannel?.dispose();
  }

  // ---------------------------------------------------------------------------
  // Logging helpers
  // ---------------------------------------------------------------------------

  Future<void> _logInfo(String message, {LumideOutputChannel? channel}) async {
    final target = channel ?? _runChannel;
    await target?.appendLog(
      LumideLogRecord(
        level: 'INFO',
        message: message,
        name: 'Lumide',
        time: DateTime.now(),
      ),
    );
  }

  Future<void> _logError(String message,
      [Object? error, LumideOutputChannel? channel]) async {
    final target = channel ?? _runChannel;
    await target?.appendLog(
      LumideLogRecord(
        level: 'ERROR',
        message: message,
        name: 'Lumide',
        error: error?.toString(),
        time: DateTime.now(),
      ),
    );
  }
}
