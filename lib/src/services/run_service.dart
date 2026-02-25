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
  StreamSubscription<String>? _stdoutProcessSub;
  StreamSubscription<String>? _stderrProcessSub;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  bool _isConnectingToVmService = false;

  VmService? _vmService;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  StreamSubscription? _loggingSub;
  String? _devToolsUrl;

  RunService(
      this.context, this.projectService, this.sdkManager, this.deviceService);

  Future<void> init() async {
    // Read configuration
    final logLimit =
        await context.workspace.getConfiguration(confLogEntryLimit) as int? ??
            defaultLogEntryLimit;

    // Create output channels
    _runChannel = await context.window
        .createOutputChannel(channelFlutter, maxEntries: logLimit);
    _buildChannel = await context.window
        .createOutputChannel(channelBuildOutput, maxEntries: logLimit);

    // Register initial Toolbar items
    await _showRunControls(isRunning: false);

    // Auto-reload on save
    context.workspace.onDidSaveTextDocument((uri) async {
      if (_isRunning && _process != null) {
        if (uri.endsWith('.dart')) {
          final shouldReload = await context.workspace
                  .getConfiguration(confHotReloadOnSave) as bool? ??
              defaultHotReloadOnSave;

          if (shouldReload) {
            await hotReload();
          }
        }
      }
    });
  }

  Future<void> _showRunControls({required bool isRunning}) async {
    if (isRunning) {
      // Hide Run, Show Stop/Reload/Restart
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
      // Show Run, Hide others
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
    final args = ['run', '-d', deviceId];

    try {
      await context.window.showMessage('Running on $deviceId');
      await _buildChannel?.show(); // SHow build channel initially

      String executable = flutterCmd.first;
      List<String> finalArgs = [...flutterCmd.sublist(1), ...args];

      await _logInfo('Launching $executable ${finalArgs.join(' ')}...',
          channel: _buildChannel);

      _process = await Process.start(
        executable,
        finalArgs,
        workingDirectory: root,
      );

      _isRunning = true;
      await _showRunControls(isRunning: true);

      // Stream stdout (Build logs + VM Uri)
      if (_process case final proc?) {
        _stdoutProcessSub = proc.stdout.transform(utf8.decoder).listen((data) {
          _buildChannel?.append(data);

          _checkForVmService(data);
          _checkForDevToolsUrl(data);
          _checkForReloadStatus(data);
        });

        // Stream stderr
        _stderrProcessSub = proc.stderr.transform(utf8.decoder).listen((data) {
          // Errors usually go to build channel during build, or run channel if running
          if (_vmService == null) {
            _buildChannel?.append('[ERR] $data');
          } else {
            _runChannel?.append('[ERR] $data');
          }
        });

        // ignore: unawaited_futures
        proc.exitCode.then((code) async {
          _isRunning = false;
          _process = null;
          _devToolsUrl = null;
          await _stdoutProcessSub?.cancel();
          _stdoutProcessSub = null;
          await _stderrProcessSub?.cancel();
          _stderrProcessSub = null;
          await _disconnectVmService();
          await _showRunControls(isRunning: false);
          await _logInfo('exited with code $code.', channel: _buildChannel);
        });
      }
    } catch (err) {
      await context.window.showMessage(
        'Failed to launch: $err',
        type: MessageType.error,
      );
      await _logError('Run error: $err', err, _buildChannel);
      _isRunning = false;
      _process = null;
      await _showRunControls(isRunning: false);
    }
  }

  void _checkForVmService(String data) {
    // Regex matches "available at" or "listening on" followed by http/ws URI
    final match = regexVmService.firstMatch(data);

    if (match != null && match.group(0) is String) {
      String uriStr = match.group(0)!.split(' ').last;

      if (uriStr.startsWith('http')) {
        uriStr = uriStr.replaceFirst('http', 'ws');
        if (uriStr.endsWith('/')) {
          uriStr += 'ws';
        } else {
          uriStr += '/ws';
        }
      }
      _connectToVmService(uriStr);
    }
  }

  void _checkForDevToolsUrl(String data) {
    // Regex matches "The Flutter DevTools ... available at: http://..."
    final match = regexDevTools.firstMatch(data);

    if (match != null) {
      final url = match.group(1);
      if (url != null) {
        _devToolsUrl = url;
        context.window.showMessage('DevTools available at $url');
      }
    }
  }

  void _checkForReloadStatus(String data) {
    final reloadMatch = regexHotReload.firstMatch(data);
    if (reloadMatch != null) {
      final n = reloadMatch.group(1);
      final m = reloadMatch.group(2);
      final ms = reloadMatch.group(3);
      context.window
          .showMessage('Hot Reload completed ($n of $m libraries in ${ms}ms)');
      return;
    }

    final restartMatch = regexHotRestart.firstMatch(data);
    if (restartMatch != null) {
      final ms = restartMatch.group(1);
      context.window.showMessage('Hot Restart completed in ${ms}ms');
    }
  }

  Future<void> _connectToVmService(String wsUri) async {
    if (_vmService != null || _isConnectingToVmService) return;
    _isConnectingToVmService = true;

    try {
      await _runChannel?.show(); // Switch to run channel
      await _logInfo('Connecting to VM Service at $wsUri...');

      final vmService = await vmServiceConnectUri(wsUri);
      _vmService = vmService;

      if (_vmService case final service?) {
        await service.streamListen(EventStreams.kStdout);
        await service.streamListen(EventStreams.kStderr);
        await service.streamListen(EventStreams.kLogging);

        _stdoutSub = service.onStdoutEvent.listen((event) {
          if (event.kind == EventKind.kWriteEvent && event.bytes != null) {
            final bytes = base64Decode(event.bytes!);
            final str = utf8.decode(bytes);
            _runChannel?.append(str);
          }
        });

        _stderrSub = service.onStderrEvent.listen((event) {
          if (event.kind == EventKind.kWriteEvent && event.bytes != null) {
            final bytes = base64Decode(event.bytes!);
            final str = utf8.decode(bytes);
            _runChannel?.append(str);
          }
        });

        _loggingSub = service.onLoggingEvent.listen((event) async {
          final logRecord = event.logRecord;
          if (logRecord != null) {
            final level = logRecord.level != null
                ? _getLogLevelName(logRecord.level!)
                : 'LOG';
            final message = logRecord.message?.valueAsString ?? '';

            // Fetch validation string for error and stackTrace if needed
            final isolateId = event.isolate?.id;
            final error = await _getStringValue(logRecord.error, isolateId);
            final stack =
                await _getStringValue(logRecord.stackTrace, isolateId);

            // Inherit level or default to LOG
            String finalLevel = level;

            // If there is an error, treat it as an ERROR level log if it's not already worse
            if (error != null && error.isNotEmpty) {
              finalLevel = 'ERROR';
            }

            final name = logRecord.loggerName?.valueAsString;
            final time = logRecord.time != null
                ? DateTime.fromMillisecondsSinceEpoch(logRecord.time!)
                : null;

            final record = LumideLogRecord(
              level: finalLevel,
              message: message,
              name: name,
              error: error,
              stackTrace: stack,
              time: time,
            );

            unawaited(_runChannel?.appendLog(record));
          }
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
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _loggingSub?.cancel();
    await _vmService?.dispose();
    _vmService = null;
  }

  Future<void> hotReload() async {
    if (!_isRunning || _process == null) return;
    if (_process case final proc?) {
      proc.stdin.write('r');
      await _logInfo('Hot Reload request sent.');
    }
  }

  Future<void> hotRestart() async {
    if (!_isRunning || _process == null) return;
    if (_process case final proc?) {
      final shouldClear = await context.workspace
              .getConfiguration(confClearLogOnHotRestart) as bool? ??
          defaultClearLogOnHotRestart;

      if (shouldClear) {
        await _runChannel?.clear();
      }

      proc.stdin.write('R');
      await _logInfo('Hot Restart request sent.');
    }
  }

  Future<void> openDevTools() async {
    if (!_isRunning || _process == null) return;

    if (_devToolsUrl != null) {
      await context.window.showMessage('Opening DevTools in browser');
      await context.window.openUrl(_devToolsUrl!);
      return;
    }

    if (_process case final proc?) {
      await context.window.showMessage(
        'DevTools URL not available yet. Requesting from Flutter',
      );
      proc.stdin.write('v');
    }
  }

  Future<void> openDevToolsInWebview() async {
    if (!_isRunning || _process == null) return;

    if (_devToolsUrl != null) {
      // Create webview panel
      await context.window.createWebviewPanel(
        'flutter.devtools',
        'Flutter DevTools',
        options: {'url': _devToolsUrl},
      );
      return;
    }

    if (_process case final proc?) {
      await context.window.showMessage(
        'DevTools URL not ready yet — requesting from Flutter',
      );
      // Trigger generation if not ready, but we can't easily wait for it here without a completer.
      // For now, just send 'v' and let the user know to try again.
      // Ideally we'd use a Completer checking `_devToolsUrl`.
      proc.stdin.write('v');
    }
  }

  Future<void> sendStdin(String char) async {
    if (!_isRunning || _process == null) return;
    if (_process case final proc?) {
      proc.stdin.write(char);
    }
  }

  Future<void> stop() async {
    if (!_isRunning || _process == null) return;
    if (_process case final proc?) {
      await context.window.showMessage('Stopping Flutter app');
      proc.stdin.write('q');
      proc.kill();

      // Wait for the process to actually exit, with a timeout to avoid hanging.
      await proc.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          // Force kill if it hasn't exited.
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      await _stdoutProcessSub?.cancel();
      _stdoutProcessSub = null;
      await _stderrProcessSub?.cancel();
      _stderrProcessSub = null;

      _isRunning = false;
      _process = null;
      _devToolsUrl = null;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _disconnectVmService();
    await _runChannel?.dispose();
    await _buildChannel?.dispose();
  }

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
