import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/daemon_service.dart';
import 'package:lumide_flutter/src/services/device_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/target_service.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

enum _FlutterLaunchMode {
  run,
  debug,
}

class _InstalledVmBreakpoint {
  const _InstalledVmBreakpoint({
    required this.requested,
    this.vmBreakpoint,
    this.message,
  });

  final LumideDebugBreakpoint requested;
  final Breakpoint? vmBreakpoint;
  final String? message;
}

class _VariableReferenceEntry {
  const _VariableReferenceEntry({
    required this.value,
    required this.isolateId,
    this.evaluateName,
  });

  final dynamic value;
  final String? isolateId;
  final String? evaluateName;
}

class RunService {
  static const String _debugSessionId = 'flutter.debug.session';
  static const String _debugSessionName = 'Flutter Debug';
  static const LumideDebugCapabilities _debugCapabilities =
      LumideDebugCapabilities(
    canLaunch: true,
    canContinue: true,
    canPause: true,
    canStepOver: true,
    canStepInto: true,
    canStepOut: true,
    canStop: true,
    canSetBreakpoints: true,
    canEvaluate: true,
  );

  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final DeviceService deviceService;
  final TargetService targetService;
  final DaemonService daemonService;

  LumideOutputChannel? _channel;
  LumideOutputChannel? get channel => _channel;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  bool get _isDebugMode => _launchMode == _FlutterLaunchMode.debug;

  bool _isConnectingToVmService = false;

  VmService? _vmService;
  StreamSubscription<Event>? _vmDebugSub;
  StreamSubscription<Event>? _vmStdoutSub;
  StreamSubscription<Event>? _vmStderrSub;
  StreamSubscription<Event>? _vmLoggingSub;
  String? _devToolsUrl;
  String? _devToolsServerHost;
  int? _devToolsServerPort;
  String? _wsUri;

  LumideWebviewPanel? _devToolsPanel;

  String? _activeAppId;
  String? _activeIsolateId;
  _FlutterLaunchMode? _launchMode;
  bool _hasDebugSession = false;
  bool _didReceiveInitialBreakpointRequest = false;
  bool _breakpointsSyncedForActiveIsolate = false;
  bool _initialPauseReached = false;
  bool _initialResumePending = false;
  int _requestId = 0;
  int _pendingLogCount = 0;
  int _maxPendingLogs = defaultMaxPendingLogs;
  int _pressureThreshold = defaultPressureThreshold;
  LumideDebugExceptionPauseMode _exceptionPauseMode =
      LumideDebugExceptionPauseMode.unhandled;
  LumideDebugSessionState _debugSessionState =
      LumideDebugSessionState.launching;
  String? _debugStoppedReason;
  String? _debugStatusMessage;
  int? _debugActiveFrameId;
  List<LumideDebugBreakpoint> _requestedDebugBreakpoints = const [];
  Map<String, _InstalledVmBreakpoint> _installedBreakpointsByKey = {};
  final Map<int, Frame> _framesById = {};
  final Map<int, List<BoundVariable>> _variablesByFrameId = {};
  final Map<int, _VariableReferenceEntry> _variableReferencesById = {};
  int _nextVariableReference = 1;

  RunService(
    this.context,
    this.projectService,
    this.sdkManager,
    this.deviceService,
    this.targetService,
    this.daemonService,
  );

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

    context.debug.onLaunch(debug);
    context.debug.onContinue(_handleDebugContinue);
    context.debug.onPause(_handleDebugPause);
    context.debug.onStepOver(_handleDebugStepOver);
    context.debug.onStepInto(_handleDebugStepInto);
    context.debug.onStepOut(_handleDebugStepOut);
    context.debug.onStop(_handleDebugStop);
    context.debug.onSetBreakpoints(_handleDebugSetBreakpoints);
    context.debug.onSetExceptionPauseMode(_handleDebugSetExceptionPauseMode);
    context.debug.onGetStackFrames(_handleDebugGetStackFrames);
    context.debug.onGetScopes(_handleDebugGetScopes);
    context.debug.onGetVariables(_handleDebugGetVariables);
    context.debug.onEvaluate(_handleDebugEvaluate);

    await _showRunControls(isRunning: false);

    context.workspace.onDidSaveTextDocument((uri) async {
      if (!_isRunning || _activeAppId == null || !uri.endsWith('.dart')) {
        return;
      }

      final shouldReload = await context.workspace
              .getConfiguration(confHotReloadOnSave) as bool? ??
          defaultHotReloadOnSave;

      if (!shouldReload) return;
      await hotReload();
    });
  }

  Future<void> _showRunControls({required bool isRunning}) async {
    if (isRunning) {
      await context.toolbar.unregisterItem(cmdFlutterRun);
      await context.toolbar.unregisterItem(cmdFlutterDebug);

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
    await context.toolbar.registerItem(
      id: cmdFlutterDebug,
      icon: iconBug,
      tooltip: 'Debug Flutter App',
      alignment: ToolbarItemAlignment.right,
      priority: 99,
    );
  }

  Future<void> run() async {
    await _launch(_FlutterLaunchMode.run);
  }

  Future<void> debug() async {
    await _launch(_FlutterLaunchMode.debug);
  }

  Future<void> _launch(_FlutterLaunchMode mode) async {
    if (_isRunning) {
      await context.window.showMessage(
        'A Flutter app is already running. Stop it before starting a new one.',
        type: MessageType.warning,
      );
      return;
    }

    String root;
    try {
      root = await projectService.getProjectRoot();
    } catch (e) {
      await context.window.showMessage(
        e.toString().replaceFirst('Exception: ', ''),
        type: MessageType.error,
      );
      return;
    }

    final deviceId = deviceService.selectedDeviceId;
    if (deviceId == null) {
      await context.window.showMessage(
        'No device selected. Use the device picker to choose one.',
        type: MessageType.error,
      );
      return;
    }

    final flutterCmd = await sdkManager.getFlutterCommand(root);
    final args = ['run', '--machine'];
    if (mode == _FlutterLaunchMode.debug) {
      args.add('--start-paused');
    }
    args.addAll(['-d', deviceId]);

    String workingDirectory = root;
    if (targetService.selectedTarget case final targetAbsolute?) {
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

    final title =
        mode == _FlutterLaunchMode.debug ? 'Flutter Debug' : 'Flutter Run';
    final action = mode == _FlutterLaunchMode.debug ? 'Debugging' : 'Running';

    try {
      await _prepareForLaunch(mode);

      await context.window.showMessage(
        '$action on $deviceId using ${flutterCmd.join(' ')}',
        title: title,
      );
      await _channel?.clear();
      if (mode != _FlutterLaunchMode.debug) {
        await _channel?.show();
      }

      final executable = flutterCmd.first;
      final finalArgs = [...flutterCmd.sublist(1), ...args];

      await _logInfo(
        '$action: $executable ${finalArgs.join(' ')}\nWorking Directory: $workingDirectory',
      );

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
          _channel?.append(data);
        });

        unawaited(proc.exitCode.then(_handleProcessExit));
      }
    } catch (err) {
      await context.window.showMessage(
        'Failed to launch: $err',
        type: MessageType.error,
      );
      await _logError(
        '${mode == _FlutterLaunchMode.debug ? 'Debug' : 'Run'} error: $err',
        err,
      );
      _isRunning = false;
      _process = null;
      _activeAppId = null;
      _launchMode = null;
      await _disconnectVmService();
      if (mode == _FlutterLaunchMode.debug) {
        await _endDebugSession(statusMessage: 'Failed to launch: $err');
      } else {
        _resetDebugRuntime();
      }
      await _showRunControls(isRunning: false);
    }
  }

  Future<void> _prepareForLaunch(_FlutterLaunchMode mode) async {
    _launchMode = mode;
    _activeAppId = null;
    _activeIsolateId = null;
    _requestId = 0;
    _devToolsUrl = null;
    _wsUri = null;
    _clearFrameCache();
    _installedBreakpointsByKey = {};
    _didReceiveInitialBreakpointRequest = false;
    _breakpointsSyncedForActiveIsolate = false;
    _initialPauseReached = false;
    _initialResumePending = mode == _FlutterLaunchMode.debug;

    if (mode != _FlutterLaunchMode.debug) {
      _requestedDebugBreakpoints = const [];
      return;
    }

    _requestedDebugBreakpoints = const [];
    await _startDebugSession();
  }

  Future<void> _handleProcessExit(int code) async {
    final wasDebug = _isDebugMode;

    _isRunning = false;
    _process = null;
    _activeAppId = null;
    _devToolsUrl = null;
    _wsUri = null;
    _launchMode = null;

    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    await _disconnectVmService();
    await _showRunControls(isRunning: false);

    await _devToolsPanel?.dispose();
    _devToolsPanel = null;

    if (wasDebug) {
      await _endDebugSession(
        statusMessage: 'Process exited with code $code.',
      );
    } else {
      _resetDebugRuntime();
    }

    await _logInfo('Process exited with code $code.');
  }

  Future<void> _startDebugSession() async {
    _hasDebugSession = true;
    _rememberDebugSessionState(
      state: LumideDebugSessionState.launching,
      statusMessage: 'Launching Flutter debug session...',
    );
    await context.debug.startSession(
      _buildDebugSession(
        state: LumideDebugSessionState.launching,
        statusMessage: 'Launching Flutter debug session...',
      ),
    );
  }

  Future<void> _updateDebugSession({
    required LumideDebugSessionState state,
    String? stoppedReason,
    String? statusMessage,
    int? activeFrameId,
  }) async {
    if (!_hasDebugSession) return;
    _rememberDebugSessionState(
      state: state,
      stoppedReason: stoppedReason,
      statusMessage: statusMessage,
      activeFrameId: activeFrameId,
    );
    await context.debug.updateSession(
      _buildDebugSession(
        state: state,
        stoppedReason: stoppedReason,
        statusMessage: statusMessage,
        activeFrameId: activeFrameId,
      ),
    );
  }

  Future<void> _endDebugSession({String? statusMessage}) async {
    if (!_hasDebugSession) {
      _resetDebugRuntime();
      return;
    }

    if (statusMessage case final message?) {
      _rememberDebugSessionState(
        state: LumideDebugSessionState.terminated,
        statusMessage: message,
      );
      await context.debug.updateSession(
        _buildDebugSession(
          state: LumideDebugSessionState.terminated,
          statusMessage: message,
        ),
      );
    }

    await context.debug.endSession(_debugSessionId);
    _hasDebugSession = false;
    _resetDebugRuntime();
  }

  LumideDebugSession _buildDebugSession({
    required LumideDebugSessionState state,
    String? stoppedReason,
    String? statusMessage,
    int? activeFrameId,
  }) {
    return LumideDebugSession(
      id: _debugSessionId,
      name: _debugSessionName,
      state: state,
      capabilities: _debugCapabilities,
      outputChannelId: _channel?.id,
      stoppedReason: stoppedReason,
      statusMessage: statusMessage,
      activeFrameId: activeFrameId,
      exceptionPauseMode: _exceptionPauseMode,
    );
  }

  void _rememberDebugSessionState({
    required LumideDebugSessionState state,
    String? stoppedReason,
    String? statusMessage,
    int? activeFrameId,
  }) {
    _debugSessionState = state;
    _debugStoppedReason = stoppedReason;
    _debugStatusMessage = statusMessage;
    _debugActiveFrameId = activeFrameId;
  }

  Future<void> _refreshDebugSessionMetadata() async {
    if (!_hasDebugSession) return;
    await context.debug.updateSession(
      _buildDebugSession(
        state: _debugSessionState,
        stoppedReason: _debugStoppedReason,
        statusMessage: _debugStatusMessage,
        activeFrameId: _debugActiveFrameId,
      ),
    );
  }

  void _handleStdoutLine(String line) {
    if (line.isEmpty) return;

    if (!line.startsWith('[')) {
      _channel?.append('$line\n');
      return;
    }

    try {
      final decoded = jsonDecode(line);
      if (decoded is! List) return;

      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          _handleMachineEvent(item);
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
        return;

      case 'app.debugPort':
        if (params['wsUri'] case final String wsUri) {
          _wsUri = wsUri;
          unawaited(_connectToVmService(wsUri));
        }
        return;

      case 'app.devTools':
        if (params['uri'] case final String uri) {
          _devToolsUrl = uri;
          unawaited(context.window.showMessage('DevTools available at: $uri'));
        }
        return;

      case 'app.started':
        unawaited(_logInfo('App is running.'));
        return;

      case 'app.log':
        final log = params['log'] as String? ?? '';
        if (log.isNotEmpty) {
          _channel?.append('$log\n');
        }
        return;

      case 'app.progress':
        final message = params['message'] as String?;
        final finished = params['finished'] as bool? ?? false;
        final id = params['id']?.toString();

        if (message != null && !finished) {
          _channel?.append('$message\n');
        }

        if (id == null) return;

        final itemId = 'flutter.progress.$id';
        if (!finished && message != null) {
          unawaited(
            context.statusBar.createItem(
              id: itemId,
              text: message,
              alignment: 'right',
              priority: 99,
            ),
          );
          return;
        }

        if (finished) {
          unawaited(context.statusBar.disposeItem(itemId));
        }
        return;

      case 'app.stop':
        _activeAppId = null;
        return;

      case 'daemon.logMessage':
        final log = params['log'] as String? ?? '';
        if (log.isNotEmpty) {
          _channel?.append('$log\n');
        }
        return;

      case null:
        return;
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
      {'id': ++_requestId, 'method': method, 'params': params},
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
        await service.streamListen(EventStreams.kLogging);

        if (_isDebugMode) {
          await service.streamListen(EventStreams.kDebug);
        }

        _vmLoggingSub = service.onLoggingEvent.listen((event) {
          final logRecord = event.logRecord;
          if (logRecord == null) return;
          if (_pendingLogCount >= _maxPendingLogs) return;

          _pendingLogCount++;
          final underPressure = _pendingLogCount > _pressureThreshold;
          unawaited(
            _processLogRecord(event, logRecord, underPressure).whenComplete(() {
              _pendingLogCount--;
            }),
          );
        });

        if (_isDebugMode) {
          _vmDebugSub = service.onDebugEvent.listen((event) {
            unawaited(_handleVmDebugEvent(event));
          });

          await _refreshActiveIsolate();
        }

        await _logInfo('Connected to VM Service. Logs streaming...');
      }
    } catch (e) {
      await _logError('Failed to connect to VM Service', e);
    } finally {
      _isConnectingToVmService = false;
    }
  }

  Future<void> _refreshActiveIsolate() async {
    final service = _vmService;
    if (service == null) return;

    try {
      final vm = await service.getVM();
      final isolateRefs = vm.isolates ?? const <IsolateRef>[];
      if (isolateRefs.isEmpty) return;

      final isolateId = isolateRefs.first.id;
      if (isolateId == null) return;

      await _setActiveIsolate(isolateId);

      if (!_isDebugMode) return;

      final isolate = await service.getIsolate(isolateId);
      await _syncDebugStateFromPauseEvent(isolate.pauseEvent);
    } catch (e) {
      await _logError('Failed to determine active isolate', e);
    }
  }

  Future<void> _setActiveIsolate(String isolateId) async {
    if (_activeIsolateId == isolateId) return;

    _activeIsolateId = isolateId;
    _breakpointsSyncedForActiveIsolate = false;
    _installedBreakpointsByKey = {};
    _clearFrameCache();

    if (!_isDebugMode) return;

    final service = _vmService;
    if (service == null) return;

    try {
      await service.setIsolatePauseMode(
        isolateId,
        exceptionPauseMode: _vmExceptionPauseModeFor(_exceptionPauseMode),
      );
    } catch (e) {
      await _logError('Failed to configure isolate pause mode', e);
    }

    if (!_didReceiveInitialBreakpointRequest) return;
    await _syncBreakpointsToVmService();
    await _pushBreakpointStateToHost();
  }

  Future<void> _handleVmDebugEvent(Event event) async {
    final kind = event.kind;
    if (kind == null || !_isDebugMode) return;

    final isolateId = event.isolate?.id;
    if (isolateId != null &&
        (_activeIsolateId == null ||
            _activeIsolateId == isolateId ||
            _isPauseOrResumeEvent(kind))) {
      await _setActiveIsolate(isolateId);
    }

    switch (kind) {
      case EventKind.kPauseStart:
        _initialPauseReached = true;
        if (await _shouldSuppressStartupPause()) {
          return;
        }
        await _applyPausedDebugState(event);
        await _tryResumeAfterInitialBreakpointSync();
        return;

      case EventKind.kPauseBreakpoint:
      case EventKind.kPauseInterrupted:
      case EventKind.kPauseException:
      case EventKind.kPausePostRequest:
        await _applyPausedDebugState(event);
        await _tryResumeAfterInitialBreakpointSync();
        return;

      case EventKind.kPauseExit:
        await _updateDebugSession(
          state: LumideDebugSessionState.terminated,
          stoppedReason: 'exit',
          statusMessage: 'Flutter isolate paused on exit.',
        );
        return;

      case EventKind.kResume:
        await _updateDebugSession(
          state: LumideDebugSessionState.running,
          statusMessage: 'Running',
        );
        return;

      case EventKind.kBreakpointAdded:
      case EventKind.kBreakpointResolved:
      case EventKind.kBreakpointRemoved:
        _applyBreakpointEvent(kind, event.breakpoint);
        await _pushBreakpointStateToHost();
        return;

      case EventKind.kIsolateExit:
        if (isolateId != null && isolateId == _activeIsolateId) {
          _activeIsolateId = null;
          _breakpointsSyncedForActiveIsolate = false;
          _installedBreakpointsByKey = {};
          _clearFrameCache();
        }
        return;

      case EventKind.kIsolateRunnable:
      case EventKind.kIsolateReload:
        if (_didReceiveInitialBreakpointRequest) {
          await _syncBreakpointsToVmService();
          await _pushBreakpointStateToHost();
          await _tryResumeAfterInitialBreakpointSync();
        }
        return;

      case EventKind.kIsolateStart:
      case EventKind.kIsolateUpdate:
      case EventKind.kServiceExtensionAdded:
      case EventKind.kVMUpdate:
      case EventKind.kVMFlagUpdate:
        return;
    }
  }

  bool _isPauseOrResumeEvent(String kind) {
    return switch (kind) {
      EventKind.kPauseStart ||
      EventKind.kPauseBreakpoint ||
      EventKind.kPauseInterrupted ||
      EventKind.kPauseException ||
      EventKind.kPausePostRequest ||
      EventKind.kPauseExit ||
      EventKind.kResume =>
        true,
      _ => false,
    };
  }

  Future<void> _syncDebugStateFromPauseEvent(Event? pauseEvent) async {
    final kind = pauseEvent?.kind;
    if (kind == null || !_isDebugMode) return;

    switch (kind) {
      case EventKind.kResume:
        await _updateDebugSession(
          state: LumideDebugSessionState.running,
          statusMessage: 'Running',
        );
        return;

      case EventKind.kPauseStart:
        _initialPauseReached = true;
        if (await _shouldSuppressStartupPause()) {
          return;
        }
        await _applyPausedDebugState(pauseEvent!);
        await _tryResumeAfterInitialBreakpointSync();
        return;

      case EventKind.kPauseBreakpoint:
      case EventKind.kPauseInterrupted:
      case EventKind.kPauseException:
      case EventKind.kPausePostRequest:
      case EventKind.kPauseExit:
        await _applyPausedDebugState(pauseEvent!);
        await _tryResumeAfterInitialBreakpointSync();
        return;
    }
  }

  Future<void> _applyPausedDebugState(Event event) async {
    final stoppedReason = _stoppedReasonForEvent(event);
    final statusMessage = await _statusMessageForEvent(event);

    await _updateDebugSession(
      state: LumideDebugSessionState.paused,
      stoppedReason: stoppedReason,
      statusMessage: statusMessage,
      activeFrameId: event.topFrame?.index,
    );
  }

  String _stoppedReasonForEvent(Event event) {
    final kind = event.kind;
    return switch (kind) {
      EventKind.kPauseStart => 'entry',
      EventKind.kPauseException => 'exception',
      EventKind.kPauseInterrupted => 'pause',
      EventKind.kPausePostRequest => 'step',
      EventKind.kPauseExit => 'exit',
      EventKind.kPauseBreakpoint
          when (event.pauseBreakpoints ?? const []).isNotEmpty =>
        'breakpoint',
      EventKind.kPauseBreakpoint => 'step',
      _ => 'pause',
    };
  }

  Future<String> _statusMessageForEvent(Event event) async {
    final kind = event.kind;
    final exceptionRef = event.exception;
    if (kind == EventKind.kPauseException && exceptionRef != null) {
      final message = await _getStringValue(exceptionRef, event.isolate?.id);
      if (message case final value? when value.isNotEmpty) {
        return 'Paused on exception: $value';
      }
    }

    return switch (_stoppedReasonForEvent(event)) {
      'entry' => 'Paused at application start.',
      'breakpoint' => 'Paused on breakpoint.',
      'exception' => 'Paused on exception.',
      'step' => 'Paused after stepping.',
      'exit' => 'Paused on exit.',
      _ => 'Paused.',
    };
  }

  void _applyBreakpointEvent(String kind, Breakpoint? breakpoint) {
    final breakpointId = breakpoint?.id;
    if (breakpointId == null) return;

    String? matchingKey;
    _InstalledVmBreakpoint? matchingBreakpoint;

    for (final entry in _installedBreakpointsByKey.entries) {
      if (entry.value.vmBreakpoint?.id != breakpointId) continue;
      matchingKey = entry.key;
      matchingBreakpoint = entry.value;
      break;
    }

    if (matchingKey == null || matchingBreakpoint == null) return;

    if (kind == EventKind.kBreakpointRemoved) {
      _installedBreakpointsByKey.remove(matchingKey);
      return;
    }

    _installedBreakpointsByKey[matchingKey] = _InstalledVmBreakpoint(
      requested: matchingBreakpoint.requested,
      vmBreakpoint: breakpoint,
      message: matchingBreakpoint.message,
    );
  }

  Future<void> _tryResumeAfterInitialBreakpointSync() async {
    if (!_isDebugMode ||
        !_initialResumePending ||
        !_initialPauseReached ||
        !_didReceiveInitialBreakpointRequest ||
        !_breakpointsSyncedForActiveIsolate) {
      return;
    }

    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return;

    _initialResumePending = false;
    try {
      await service.resume(isolateId);
      await _logInfo(
        'Auto-resumed Flutter isolate after startup breakpoint sync.',
      );
    } catch (e) {
      _initialResumePending = true;
      await _logError(
        'Failed to resume after initial breakpoint synchronization',
        e,
      );
    }
  }

  Future<bool> _shouldSuppressStartupPause() async {
    if (!_initialResumePending) {
      return false;
    }

    if (!_didReceiveInitialBreakpointRequest ||
        !_breakpointsSyncedForActiveIsolate) {
      return true;
    }

    await _tryResumeAfterInitialBreakpointSync();
    return !_initialResumePending;
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
    String message;
    String? error;
    String? stack;

    if (underPressure) {
      message = logRecord.message?.valueAsString ?? '';
      error = logRecord.error?.valueAsString;
      stack = logRecord.stackTrace?.valueAsString;
    } else {
      final isolateId = event.isolate?.id;
      message = await _getStringValue(logRecord.message, isolateId) ?? '';
      error = await _getStringValue(logRecord.error, isolateId);
      stack = await _getStringValue(logRecord.stackTrace, isolateId);
    }

    final finalLevel = switch (error) {
      final value? when value.isNotEmpty => 'ERROR',
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

    final service = _vmService;
    if (service != null && ref.id != null && isolateId != null) {
      if (ref.valueAsStringIsTruncated == true) {
        try {
          final obj = await service.getObject(isolateId, ref.id!);
          if (obj is Instance && obj.valueAsString != null) {
            return obj.valueAsString;
          }
        } catch (_) {}
      }

      if (ref.valueAsString == null) {
        try {
          final result = await service.invoke(
            isolateId,
            ref.id ?? '',
            'toString',
            [],
            disableBreakpoints: true,
          );
          if (result case final InstanceRef instanceRef) {
            if (instanceRef.valueAsStringIsTruncated == true &&
                instanceRef.id != null) {
              final obj = await service.getObject(isolateId, instanceRef.id!);
              if (obj is Instance && obj.valueAsString != null) {
                return obj.valueAsString;
              }
            }
            return instanceRef.valueAsString;
          }
        } catch (e) {
          return 'Instance of ${ref.classRef?.name} (Error: $e)';
        }
      }
    }

    if (ref.valueAsString case final value?) return value;
    return 'Instance of ${ref.classRef?.name}';
  }

  Future<String?> _getSafeDebugStringValue(
    InstanceRef ref,
    String? isolateId,
  ) async {
    if (ref.kind == InstanceKind.kNull) return 'null';

    if (ref.valueAsStringIsTruncated == true &&
        ref.id != null &&
        isolateId != null) {
      try {
        final obj = await _vmService?.getObject(isolateId, ref.id!);
        if (obj is Instance && obj.valueAsString != null) {
          return obj.valueAsString;
        }
      } catch (_) {}
    }

    if (ref.valueAsString case final value?) return value;
    return null;
  }

  Future<String> _debugValueToString(dynamic value, String? isolateId) async {
    return switch (value) {
      null => 'null',
      InstanceRef instanceRef => await _getSafeDebugStringValue(
              instanceRef, isolateId) ??
          'Instance of ${instanceRef.classRef?.name ?? instanceRef.kind ?? 'object'}',
      TypeArgumentsRef(:final name?) when name.isNotEmpty => name,
      TypeArgumentsRef() => '<type arguments>',
      Sentinel(:final valueAsString?) when valueAsString.isNotEmpty =>
        valueAsString,
      Sentinel(:final kind?) when kind.isNotEmpty => '<$kind>',
      ObjRef(:final id?) => 'Object $id',
      _ => value.toString(),
    };
  }

  Future<void> _disconnectVmService() async {
    await _vmDebugSub?.cancel();
    _vmDebugSub = null;
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

    if (_isDebugMode) {
      _clearFrameCache();
      _initialPauseReached = false;
      _initialResumePending = true;
      await _updateDebugSession(
        state: LumideDebugSessionState.running,
        statusMessage: 'Hot restarting Flutter app...',
      );
    }

    _sendMachineCommand(
      'app.restart',
      {'fullRestart': true, 'pause': false},
    );
  }

  Future<void> continueExecution() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return;
    await service.resume(isolateId);
  }

  Future<void> pauseExecution() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return;
    await service.pause(isolateId);
  }

  Future<void> stepOver() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return;
    await service.resume(isolateId, step: StepOption.kOver);
  }

  Future<void> stepInto() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return;
    await service.resume(isolateId, step: StepOption.kInto);
  }

  Future<void> stepOut() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return;
    await service.resume(isolateId, step: StepOption.kOut);
  }

  Future<List<LumideDebugStackFrame>> getStackFrames() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return const [];

    try {
      final stack = await service.getStack(isolateId);
      final frames = stack.frames ?? const <Frame>[];
      _clearFrameCache();

      final result = <LumideDebugStackFrame>[];
      for (int index = 0; index < frames.length; index++) {
        final frame = frames[index];
        final location = frame.location;
        final sourceUri = location?.script?.uri;
        final line = location?.line;

        if (sourceUri == null || sourceUri.isEmpty || line == null) {
          continue;
        }

        final frameId = frame.index ?? index;
        _framesById[frameId] = frame;
        _variablesByFrameId[frameId] = frame.vars ?? const [];

        result.add(
          LumideDebugStackFrame(
            id: frameId,
            name: frame.function?.name ?? '<frame>',
            sourceUri: sourceUri,
            sourceName: path.basename(Uri.parse(sourceUri).path),
            line: line,
            column: location?.column ?? 1,
            endLine: location?.line,
            endColumn: location?.column,
          ),
        );
      }

      return result;
    } catch (e) {
      await _logError('Failed to load stack frames', e);
      return const [];
    }
  }

  Future<List<LumideDebugScope>> getScopes(int frameId) async {
    final frame = _framesById[frameId];
    if (frame == null) return const [];

    final variables = frame.vars ?? const <BoundVariable>[];
    _variablesByFrameId[frameId] = variables;

    return [
      LumideDebugScope(
        id: frameId,
        name: 'Locals',
        presentationHint: 'locals',
        namedVariables: variables.length,
      ),
    ];
  }

  Future<List<LumideDebugVariable>> getVariables(int variablesReference) async {
    final isolateId = _activeIsolateId;
    final variables = _variablesByFrameId[variablesReference];
    if (variables != null) {
      return _buildDebugVariablesFromBoundVariables(variables, isolateId);
    }

    final entry = _variableReferencesById[variablesReference];
    if (entry == null) return const [];
    return _buildChildVariables(entry);
  }

  Future<List<LumideDebugVariable>> _buildDebugVariablesFromBoundVariables(
    List<BoundVariable> variables,
    String? isolateId,
  ) async {
    final result = <LumideDebugVariable>[];
    for (final variable in variables) {
      result.add(
        await _buildDebugVariable(
          name: variable.name ?? '<unnamed>',
          value: variable.value,
          isolateId: isolateId,
          evaluateName: variable.name,
        ),
      );
    }
    return result;
  }

  Future<List<LumideDebugVariable>> _buildChildVariables(
    _VariableReferenceEntry entry,
  ) async {
    if (entry.value case final InstanceRef instanceRef) {
      return _buildInstanceChildVariables(
        instanceRef,
        isolateId: entry.isolateId,
        parentEvaluateName: entry.evaluateName,
      );
    }

    return const <LumideDebugVariable>[];
  }

  Future<List<LumideDebugVariable>> _buildInstanceChildVariables(
    InstanceRef instanceRef, {
    required String? isolateId,
    String? parentEvaluateName,
  }) async {
    final service = _vmService;
    final objectId = instanceRef.id;
    if (service == null || isolateId == null || objectId == null) {
      return const [];
    }

    try {
      final object = await service.getObject(isolateId, objectId);
      if (object is! Instance) return const [];

      final result = <LumideDebugVariable>[];

      for (final field in object.fields ?? const <BoundField>[]) {
        final fieldName =
            field.name?.toString() ?? field.decl?.name ?? '<field>';
        result.add(
          await _buildDebugVariable(
            name: fieldName,
            value: field.value,
            isolateId: isolateId,
            evaluateName: _fieldEvaluateName(parentEvaluateName, field.name),
          ),
        );
      }

      final elements = object.elements ?? const <dynamic>[];
      for (int index = 0; index < elements.length; index++) {
        result.add(
          await _buildDebugVariable(
            name: '[$index]',
            value: elements[index],
            isolateId: isolateId,
            evaluateName: parentEvaluateName == null
                ? null
                : '$parentEvaluateName[$index]',
          ),
        );
      }

      for (final association
          in object.associations ?? const <MapAssociation>[]) {
        final keyLabel = await _debugValueToString(association.key, isolateId);
        result.add(
          await _buildDebugVariable(
            name: '[${keyLabel.isEmpty ? '<key>' : keyLabel}]',
            value: association.value,
            isolateId: isolateId,
          ),
        );
      }

      return result;
    } catch (e) {
      await _logError('Failed to load child debug variables', e);
      return const [];
    }
  }

  Future<LumideDebugVariable> _buildDebugVariable({
    required String name,
    required dynamic value,
    required String? isolateId,
    String? evaluateName,
  }) async {
    return LumideDebugVariable(
      name: name,
      value: await _debugValueToString(value, isolateId),
      type: _debugTypeFor(value),
      evaluateName: evaluateName,
      variablesReference: _createVariablesReference(
        value,
        isolateId,
        evaluateName: evaluateName,
      ),
    );
  }

  String? _debugTypeFor(dynamic value) {
    return switch (value) {
      InstanceRef(:final classRef?) => classRef.name,
      TypeArgumentsRef(:final name?) => name,
      Sentinel(:final kind?) => kind,
      _ => null,
    };
  }

  int? _createVariablesReference(
    dynamic value,
    String? isolateId, {
    String? evaluateName,
  }) {
    if (!_isExpandableDebugValue(value) || isolateId == null) {
      return null;
    }

    final reference = _nextVariableReference++;
    _variableReferencesById[reference] = _VariableReferenceEntry(
      value: value,
      isolateId: isolateId,
      evaluateName: evaluateName,
    );
    return reference;
  }

  bool _isExpandableDebugValue(dynamic value) {
    return switch (value) {
      InstanceRef() => switch (value.kind) {
          InstanceKind.kPlainInstance ||
          InstanceKind.kRecord ||
          InstanceKind.kList ||
          InstanceKind.kSet ||
          InstanceKind.kMap =>
            true,
          _ => false,
        },
      _ => false,
    };
  }

  String? _fieldEvaluateName(String? parentEvaluateName, dynamic fieldName) {
    if (parentEvaluateName == null) return null;
    return switch (fieldName) {
      final String name when _isValidDartIdentifier(name) =>
        '$parentEvaluateName.$name',
      _ => null,
    };
  }

  bool _isValidDartIdentifier(String value) {
    final pattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    return pattern.hasMatch(value);
  }

  Future<LumideDebugEvaluationResult?> evaluate(
    String expression, {
    int? frameId,
  }) async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) return null;

    try {
      final resolvedFrameId = frameId ?? 0;
      final response = await service.evaluateInFrame(
        isolateId,
        resolvedFrameId,
        expression,
        disableBreakpoints: true,
      );

      return switch (response) {
        InstanceRef instanceRef => LumideDebugEvaluationResult(
            result: await _debugValueToString(instanceRef, isolateId),
            type: instanceRef.classRef?.name,
          ),
        ErrorRef errorRef => LumideDebugEvaluationResult(
            result: errorRef.message ?? 'Evaluation failed',
            type: errorRef.kind,
          ),
        _ => LumideDebugEvaluationResult(result: response.toString()),
      };
    } catch (e) {
      return LumideDebugEvaluationResult(
        result: 'Evaluation failed: $e',
        type: 'error',
      );
    }
  }

  Future<void> _handleDebugContinue(String sessionId) async {
    if (!_matchesDebugSession(sessionId)) return;
    await continueExecution();
  }

  Future<void> _handleDebugPause(String sessionId) async {
    if (!_matchesDebugSession(sessionId)) return;
    await pauseExecution();
  }

  Future<void> _handleDebugStepOver(String sessionId) async {
    if (!_matchesDebugSession(sessionId)) return;
    await stepOver();
  }

  Future<void> _handleDebugStepInto(String sessionId) async {
    if (!_matchesDebugSession(sessionId)) return;
    await stepInto();
  }

  Future<void> _handleDebugStepOut(String sessionId) async {
    if (!_matchesDebugSession(sessionId)) return;
    await stepOut();
  }

  Future<void> _handleDebugStop(String sessionId) async {
    if (!_matchesDebugSession(sessionId)) return;
    await stop();
  }

  Future<void> _handleDebugSetBreakpoints(
    String sessionId,
    List<LumideDebugBreakpoint> breakpoints,
  ) async {
    if (!_matchesDebugSession(sessionId)) return;

    _requestedDebugBreakpoints = _normalizeDebugBreakpoints(breakpoints);
    _didReceiveInitialBreakpointRequest = true;

    await _syncBreakpointsToVmService();
    await _pushBreakpointStateToHost();
    await _tryResumeAfterInitialBreakpointSync();
  }

  Future<void> _handleDebugSetExceptionPauseMode(
    String sessionId,
    LumideDebugExceptionPauseMode mode,
  ) async {
    if (!_matchesDebugSession(sessionId)) return;

    _exceptionPauseMode = mode;

    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service != null && isolateId != null) {
      try {
        await service.setIsolatePauseMode(
          isolateId,
          exceptionPauseMode: _vmExceptionPauseModeFor(mode),
        );
      } catch (e) {
        await _logError('Failed to update isolate pause mode', e);
      }
    }

    await _refreshDebugSessionMetadata();
  }

  Future<List<LumideDebugStackFrame>> _handleDebugGetStackFrames(
    String sessionId,
  ) async {
    if (!_matchesDebugSession(sessionId)) return const [];
    return getStackFrames();
  }

  Future<List<LumideDebugScope>> _handleDebugGetScopes(
    String sessionId,
    int frameId,
  ) async {
    if (!_matchesDebugSession(sessionId)) return const [];
    return getScopes(frameId);
  }

  Future<List<LumideDebugVariable>> _handleDebugGetVariables(
    String sessionId,
    int scopeId,
  ) async {
    if (!_matchesDebugSession(sessionId)) return const [];
    return getVariables(scopeId);
  }

  Future<LumideDebugEvaluationResult?> _handleDebugEvaluate(
    String sessionId,
    String expression, {
    int? frameId,
  }) async {
    if (!_matchesDebugSession(sessionId)) return null;
    return evaluate(expression, frameId: frameId);
  }

  bool _matchesDebugSession(String sessionId) {
    return _hasDebugSession && sessionId == _debugSessionId;
  }

  Future<void> _syncBreakpointsToVmService() async {
    final service = _vmService;
    final isolateId = _activeIsolateId;
    if (service == null || isolateId == null) {
      _breakpointsSyncedForActiveIsolate = false;
      return;
    }

    final desiredBreakpoints = <String, LumideDebugBreakpoint>{
      for (final breakpoint in _requestedDebugBreakpoints)
        if (breakpoint.enabled) _breakpointKeyFor(breakpoint): breakpoint,
    };

    final staleKeys = _installedBreakpointsByKey.keys
        .where((key) => !desiredBreakpoints.containsKey(key))
        .toList();

    for (final key in staleKeys) {
      final installed = _installedBreakpointsByKey.remove(key);
      final breakpointId = installed?.vmBreakpoint?.id;
      if (breakpointId == null) continue;

      try {
        await service.removeBreakpoint(isolateId, breakpointId);
      } catch (e) {
        await _logError('Failed to remove breakpoint', e);
      }
    }

    for (final entry in desiredBreakpoints.entries) {
      final existing = _installedBreakpointsByKey[entry.key];
      if (existing?.vmBreakpoint != null) continue;

      try {
        final vmBreakpoint = await _addVmBreakpointWithFallback(
          service: service,
          isolateId: isolateId,
          breakpoint: entry.value,
        );

        _installedBreakpointsByKey[entry.key] = _InstalledVmBreakpoint(
          requested: entry.value,
          vmBreakpoint: vmBreakpoint,
        );
      } catch (e) {
        _installedBreakpointsByKey[entry.key] = _InstalledVmBreakpoint(
          requested: entry.value,
          message: e.toString(),
        );
      }
    }

    _breakpointsSyncedForActiveIsolate = true;
  }

  Future<Breakpoint> _addVmBreakpointWithFallback({
    required VmService service,
    required String isolateId,
    required LumideDebugBreakpoint breakpoint,
  }) async {
    final candidateUris = await _breakpointCandidateUris(
      service: service,
      isolateId: isolateId,
      sourceUri: breakpoint.sourceUri,
    );

    Object? lastError;
    for (final candidateUri in candidateUris) {
      try {
        return await service.addBreakpointWithScriptUri(
          isolateId,
          candidateUri,
          breakpoint.line,
          column: breakpoint.column,
        );
      } catch (error) {
        lastError = error;
      }
    }

    throw lastError ??
        StateError('Failed to add breakpoint for ${breakpoint.sourceUri}');
  }

  Future<List<String>> _breakpointCandidateUris({
    required VmService service,
    required String isolateId,
    required String sourceUri,
  }) async {
    final candidates = <String>[sourceUri];
    final parsedUri = Uri.tryParse(sourceUri);
    if (parsedUri == null || parsedUri.scheme != 'file') {
      return candidates;
    }

    try {
      final packageUris = await service.lookupPackageUris(
        isolateId,
        [sourceUri],
      );
      final uris = packageUris.uris;
      final packageUri = uris != null && uris.isNotEmpty ? uris.first : null;
      if (packageUri != null &&
          packageUri.isNotEmpty &&
          !candidates.contains(packageUri)) {
        candidates.add(packageUri);
      }
    } catch (_) {}

    return candidates;
  }

  Future<void> _pushBreakpointStateToHost() async {
    if (!_hasDebugSession) return;

    final breakpoints = _requestedDebugBreakpoints.map((breakpoint) {
      final installed =
          _installedBreakpointsByKey[_breakpointKeyFor(breakpoint)];

      return LumideDebugBreakpoint(
        id: installed?.vmBreakpoint?.id ?? breakpoint.id,
        sourceUri: breakpoint.sourceUri,
        line: breakpoint.line,
        column: breakpoint.column,
        endLine: breakpoint.endLine,
        endColumn: breakpoint.endColumn,
        condition: breakpoint.condition,
        enabled: breakpoint.enabled,
        verified: installed?.vmBreakpoint?.resolved ?? false,
        message: _breakpointMessageFor(breakpoint, installed),
      );
    }).toList(growable: false);

    await context.debug.updateBreakpoints(_debugSessionId, breakpoints);
  }

  String _vmExceptionPauseModeFor(
    LumideDebugExceptionPauseMode mode,
  ) {
    return switch (mode) {
      LumideDebugExceptionPauseMode.none => ExceptionPauseMode.kNone,
      LumideDebugExceptionPauseMode.unhandled => ExceptionPauseMode.kUnhandled,
      LumideDebugExceptionPauseMode.all => ExceptionPauseMode.kAll,
    };
  }

  String? _breakpointMessageFor(
    LumideDebugBreakpoint requested,
    _InstalledVmBreakpoint? installed,
  ) {
    if (!requested.enabled) {
      return 'Disabled';
    }

    if (installed case final value? when value.message != null) {
      return value.message;
    }

    final vmBreakpoint = installed?.vmBreakpoint;
    if (vmBreakpoint == null) {
      return switch ((_activeIsolateId, _didReceiveInitialBreakpointRequest)) {
        (null, _) => 'Waiting for isolate',
        (_, false) => 'Waiting for host synchronization',
        _ => 'Pending install',
      };
    }

    if (vmBreakpoint.resolved == true) return null;
    return 'Pending resolution';
  }

  String _breakpointKeyFor(LumideDebugBreakpoint breakpoint) {
    final column = breakpoint.column ?? 0;
    return '${breakpoint.sourceUri}:${breakpoint.line}:$column';
  }

  List<LumideDebugBreakpoint> _normalizeDebugBreakpoints(
    List<LumideDebugBreakpoint> breakpoints,
  ) {
    final deduped = <String, LumideDebugBreakpoint>{};

    for (final breakpoint in breakpoints) {
      deduped[_breakpointKeyFor(breakpoint)] = breakpoint;
    }

    final normalized = deduped.values.toList()
      ..sort((left, right) {
        final uriCompare = left.sourceUri.compareTo(right.sourceUri);
        if (uriCompare != 0) return uriCompare;

        final lineCompare = left.line.compareTo(right.line);
        if (lineCompare != 0) return lineCompare;

        final leftColumn = left.column ?? 0;
        final rightColumn = right.column ?? 0;
        return leftColumn.compareTo(rightColumn);
      });

    return List.unmodifiable(normalized);
  }

  Future<String?> _getOrCreateDevToolsUrl() async {
    if (_devToolsUrl != null) return _devToolsUrl;
    if (_wsUri == null) return null;

    if (_devToolsServerHost == null || _devToolsServerPort == null) {
      try {
        final result = await daemonService.serveDevTools();
        if (result['host'] != null && result['port'] != null) {
          _devToolsServerHost = result['host'] as String?;
          _devToolsServerPort = result['port'] as int?;
        }
      } catch (e) {
        daemonService.logService.error('Failed to start DevTools server', e);
        return null;
      }
    }

    if (_devToolsServerHost != null && _devToolsServerPort != null) {
      final encodedUri = Uri.encodeComponent(_wsUri!);
      _devToolsUrl =
          'http://$_devToolsServerHost:$_devToolsServerPort/?uri=$encodedUri';
    }

    return _devToolsUrl;
  }

  Future<void> openDevTools() async {
    if (!_isRunning) return;

    final url = await _getOrCreateDevToolsUrl();
    if (url != null) {
      await context.window.showMessage('Opening DevTools in browser');
      await context.window.openUrl(url);
      return;
    }

    await context.window.showMessage(
      'DevTools URL not available yet. Try again shortly.',
    );
  }

  Future<void> openDevToolsInWebview() async {
    if (!_isRunning) return;

    final url = await _getOrCreateDevToolsUrl();
    if (url != null) {
      await _devToolsPanel?.dispose();
      _devToolsPanel = await context.window.createWebviewPanel(
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

    await context.window.showMessage(
      'Stopping Flutter app',
      title: _isDebugMode ? 'Flutter Debug' : 'Flutter Run',
    );

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
  }

  void _clearFrameCache() {
    _framesById.clear();
    _variablesByFrameId.clear();
    _variableReferencesById.clear();
    _nextVariableReference = 1;
  }

  void _resetDebugRuntime() {
    _activeIsolateId = null;
    _requestedDebugBreakpoints = const [];
    _installedBreakpointsByKey = {};
    _didReceiveInitialBreakpointRequest = false;
    _breakpointsSyncedForActiveIsolate = false;
    _initialPauseReached = false;
    _initialResumePending = false;
    _debugSessionState = LumideDebugSessionState.launching;
    _debugStoppedReason = null;
    _debugStatusMessage = null;
    _debugActiveFrameId = null;
    _clearFrameCache();
  }

  Future<void> dispose() async {
    await stop();
    await _disconnectVmService();
    if (_hasDebugSession) {
      await context.debug.endSession(_debugSessionId);
      _hasDebugSession = false;
    }
    await _channel?.dispose();

    await _devToolsPanel?.dispose();
    _devToolsPanel = null;
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
