import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/device_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/target_service.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class RunService {
  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final DeviceService deviceService;
  final TargetService targetService;

  LumideOutputChannel? _channel;
  LumideOutputChannel? get channel => _channel;

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
  int _pendingLogCount = 0;
  int _maxPendingLogs = defaultMaxPendingLogs;
  int _pressureThreshold = defaultPressureThreshold;
  RunService(this.context, this.projectService, this.sdkManager,
      this.deviceService, this.targetService);

  Future<void> init() async {
    final logLimit =
        await context.workspace.getConfiguration(confLogEntryLimit) as int? ??
            defaultLogEntryLimit;

    _channel = await context.window
        .createOutputChannel(channelFlutter, maxEntries: logLimit);

    _maxPendingLogs =
        await context.workspace.getConfiguration(confMaxPendingLogs) as int? ??
            defaultMaxPendingLogs;
    _pressureThreshold = await context.workspace
            .getConfiguration(confPressureThreshold) as int? ??
        defaultPressureThreshold;

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
      return;
    }

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

  Future<void> run() async {
    if (_isRunning) {
      await context.window.showMessage(
          'A Flutter app is already running. Stop it before starting a new one.',
          type: MessageType.warning);
      return;
    }

    String root;
    try {
      root = await projectService.getProjectRoot();
    } catch (e) {
      await context.window.showMessage(
          e.toString().replaceFirst('Exception: ', ''),
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

    String workingDirectory = root;
    if (targetService.selectedTarget != null) {
      final targetAbsolute = targetService.selectedTarget!;

      // Determine the nearest package root by searching upwards for pubspec.yaml
      String packageRoot = path.dirname(targetAbsolute);
      while (packageRoot != root && packageRoot.length >= root.length) {
        final pubspecPath = path.join(packageRoot, 'pubspec.yaml');
        if (await context.fs.exists(pubspecPath)) {
          break;
        }
        packageRoot = path.dirname(packageRoot);
      }

      if (packageRoot.length < root.length) {
        packageRoot = root;
      }

      workingDirectory = packageRoot;
      final relativeTarget = path.relative(targetAbsolute, from: packageRoot);
      args.addAll(['-t', relativeTarget]);
    }
    try {
      await context.window.showMessage(
        'Running on $deviceId using ${flutterCmd.join(' ')}',
        title: 'Flutter Run',
      );
      await _channel?.clear();
      await _channel?.show();

      final executable = flutterCmd.first;
      final finalArgs = [...flutterCmd.sublist(1), ...args];

      await _logInfo(
          'Running: $executable ${finalArgs.join(' ')}\nWorking Directory: $workingDirectory');

      _activeAppId = null;
      _requestId = 0;
      _devToolsUrl = null;

      _process = await Process.start(
        executable,
        finalArgs,
        workingDirectory: workingDirectory,
      );

      _isRunning = true;
      await _showRunControls(isRunning: true);

      if (_process case final proc?) {
        _stdoutSub = proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_handleStdoutLine);

        _stderrSub = proc.stderr.transform(utf8.decoder).listen((data) {
          _channel?.append('[ERR] $data');
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
          await _logInfo('Process exited with code $code.');
        }));
      }
    } catch (err) {
      await context.window.showMessage(
        'Failed to launch: $err',
        type: MessageType.error,
      );
      await _logError('Run error: $err', err);
      _isRunning = false;
      _process = null;
      _activeAppId = null;
      await _showRunControls(isRunning: false);
    }
  }

  void _handleStdoutLine(String line) {
    if (line.isEmpty) return;

    if (!line.startsWith('[')) {
      _channel?.append('$line\n');
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
      _channel?.append('$line\n');
    }
  }

  void _handleMachineEvent(Map<String, dynamic> event) {
    final eventName = event['event'] as String?;
    final params = event['params'] as Map<String, dynamic>? ?? {};

    switch (eventName) {
      case 'app.start':
        _activeAppId = params['appId'] as String?;

      case 'app.debugPort':
        if (params['wsUri'] case final String wsUri) {
          _connectToVmService(wsUri);
        }
        if (params['baseUri'] case final String baseUri) {
          _devToolsUrl = baseUri;
        }

      case 'app.started':
        _logInfo('App is running.');

      case 'app.log':
        final log = params['log'] as String? ?? '';
        if (log.isNotEmpty) {
          _channel?.append('$log\n');
        }

      case 'app.progress':
        final message = params['message'] as String?;
        final finished = params['finished'] as bool? ?? false;
        if (message != null && !finished) {
          _channel?.append('$message\n');
        }

      case 'app.stop':
        _activeAppId = null;

      case 'daemon.logMessage':
        final log = params['log'] as String? ?? '';
        if (log.isNotEmpty) {
          _channel?.append('$log\n');
        }
    }
  }

  void _sendMachineCommand(
    String method, [
    Map<String, dynamic>? extraParams,
  ]) {
    final appId = _activeAppId;
    final proc = _process;
    if (proc == null || appId == null) return;

    final params = <String, dynamic>{'appId': appId};
    if (extraParams != null) {
      params.addAll(extraParams);
    }

    final payload = [
      {'id': ++_requestId, 'method': method, 'params': params}
    ];
    proc.stdin.writeln(jsonEncode(payload));
  }

  Future<void> _connectToVmService(String wsUri) async {
    if (_vmService != null || _isConnectingToVmService) return;
    _isConnectingToVmService = true;

    try {
      await _logInfo('Connecting to VM Service at $wsUri...');

      final vmService = await vmServiceConnectUri(wsUri);
      _vmService = vmService;

      if (_vmService case final service?) {
        await service.streamListen(EventStreams.kStdout);
        await service.streamListen(EventStreams.kStderr);
        await service.streamListen(EventStreams.kLogging);

        _vmStdoutSub = service.onStdoutEvent.listen((event) {
          if (event.kind == EventKind.kWriteEvent) {
            if (event.bytes case final String bytes) {
              _channel?.append(utf8.decode(base64Decode(bytes)));
            }
          }
        });

        _vmStderrSub = service.onStderrEvent.listen((event) {
          if (event.kind == EventKind.kWriteEvent) {
            if (event.bytes case final String bytes) {
              _channel?.append(utf8.decode(base64Decode(bytes)));
            }
          }
        });

        _vmLoggingSub = service.onLoggingEvent.listen((event) {
          final logRecord = event.logRecord;
          if (logRecord == null) return;

          if (_pendingLogCount >= _maxPendingLogs) return;
          _pendingLogCount++;

          final underPressure = _pendingLogCount > _pressureThreshold;

          unawaited(_processLogRecord(event, logRecord, underPressure)
              .whenComplete(() {
            _pendingLogCount--;
          }));
        });

        await _logInfo('Connected to VM Service. Logs streaming...');
      }
    } catch (e) {
      await _logError('Failed to connect to VM Service', e);
    } finally {
      _isConnectingToVmService = false;
    }
  }

  String _getLogLevelName(int level) => switch (level) {
        >= 1000 => 'ERROR',
        >= 900 => 'WARN',
        >= 800 => 'INFO',
        >= 700 => 'CONFIG',
        >= 500 => 'FINE',
        _ => 'DEBUG',
      };

  Future<void> _processLogRecord(
    Event event,
    LogRecord logRecord,
    bool underPressure,
  ) async {
    final level = switch (logRecord.level) {
      final lvl? => _getLogLevelName(lvl),
      null => 'LOG',
    };
    final message = logRecord.message?.valueAsString ?? '';

    String? error;
    String? stack;

    if (underPressure) {
      error = logRecord.error?.valueAsString;
      stack = logRecord.stackTrace?.valueAsString;
    } else {
      final isolateId = event.isolate?.id;
      error = await _getStringValue(logRecord.error, isolateId);
      stack = await _getStringValue(logRecord.stackTrace, isolateId);
    }

    final finalLevel = switch (error) {
      final e? when e.isNotEmpty => 'ERROR',
      _ => level,
    };

    final record = LumideLogRecord(
      level: finalLevel,
      message: message,
      name: logRecord.loggerName?.valueAsString,
      error: error,
      stackTrace: stack,
      time: switch (logRecord.time) {
        final t? => DateTime.fromMillisecondsSinceEpoch(t),
        null => null,
      },
    );

    unawaited(_channel?.appendLog(record));
  }

  Future<String?> _getStringValue(InstanceRef? ref, String? isolateId) async {
    if (ref == null) return null;
    if (ref.kind == InstanceKind.kNull) return null;
    if (ref.valueAsString == 'null') return null;
    if (ref.valueAsString case final value?) return value;

    if (_vmService case final service?
        when ref.id != null && isolateId != null) {
      try {
        final result = await service.invoke(
          isolateId,
          ref.id ?? '',
          'toString',
          [],
          disableBreakpoints: true,
        );
        if (result case final InstanceRef instanceRef) {
          return instanceRef.valueAsString;
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

  Future<void> hotReload() async {
    if (!_isRunning || _activeAppId == null) return;
    _sendMachineCommand(
      'app.restart',
      {'fullRestart': false, 'pause': false},
    );
  }

  Future<void> hotRestart() async {
    if (!_isRunning || _activeAppId == null) return;

    final shouldClear = await context.workspace
            .getConfiguration(confClearLogOnHotRestart) as bool? ??
        defaultClearLogOnHotRestart;

    if (shouldClear) {
      await _channel?.clear();
    }

    _sendMachineCommand(
      'app.restart',
      {'fullRestart': true, 'pause': false},
    );
  }

  Future<void> openDevTools() async {
    if (!_isRunning) return;

    if (_devToolsUrl case final url?) {
      await context.window.showMessage('Opening DevTools in browser');
      await context.window.openUrl(url);
      return;
    }

    _sendMachineCommand(
      'app.callServiceExtension',
      {'methodName': 'ext.flutter.activeDevToolsServerAddress'},
    );
    await context.window.showMessage(
      'DevTools URL not available yet. Try again shortly.',
    );
  }

  Future<void> openDevToolsInWebview() async {
    if (!_isRunning) return;

    if (_devToolsUrl case final url?) {
      await context.window.createWebviewPanel(
        'flutter.devtools',
        'Flutter DevTools',
        options: {'url': url},
      );
      return;
    }

    await context.window.showMessage(
      'DevTools URL not ready yet. Try again shortly.',
    );
  }

  Future<void> stop() async {
    if (!_isRunning || _process == null) return;

    final confirm = await context.window.showConfirmDialog(
      'Are you sure you want to stop the running Flutter application?',
      title: 'Stop Application',
    );
    if (!confirm) return;

    await context.window
        .showMessage('Stopping Flutter app', title: 'Flutter Run');

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

  Future<void> dispose() async {
    await stop();
    await _disconnectVmService();
    await _channel?.dispose();
  }

  Future<void> _logInfo(String message) async {
    await _channel?.appendLog(
      LumideLogRecord(
        level: 'INFO',
        message: message,
        name: 'Lumide',
        time: DateTime.now(),
      ),
    );
  }

  Future<void> _logError(String message, [Object? error]) async {
    await _channel?.appendLog(
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
