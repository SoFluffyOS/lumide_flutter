import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/hot_reload_controller.dart';
import 'package:lumide_flutter/src/services/machine_requests.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
import 'package:path/path.dart' as path;

/// One app `flutter run --machine` or `flutter attach --machine` runs: the
/// launch Lumide knows it by, its daemon process, and what the daemon told
/// of the app.
class FlutterRun {
  FlutterRun({
    required this.kind,
    required this.configurationId,
    required this.process,
    this.workspaceFolder,
    this.deviceId,
    AppRestartResultHandler? onRestartResult,
  }) {
    reloads = HotReloadController(
      send: restartApp,
      onResult: onRestartResult,
    );
  }

  final LumideLaunchKind kind;
  final String configurationId;

  /// The folder Lumide started the launch in, as it named it; null for runs
  /// started without a configuration.
  final String? workspaceFolder;
  final String? deviceId;
  final SdkProcess process;

  /// Reloads and restarts of this app, one at a time.
  late final HotReloadController reloads;

  /// The app's id in its daemon, once `app.start` gave it.
  String? appId;

  /// The app's VM service, once `app.debugPort` gave it.
  String? vmServiceUri;
  String? devToolsUrl;

  StreamSubscription<String>? stdoutSubscription;
  StreamSubscription<String>? stderrSubscription;

  final _requests = MachineRequests();

  /// The restart in flight, by its request id, and the errors logged since
  /// it was sent.
  ({int id, List<String> errors})? _restart;

  bool get isAttach => kind == LumideLaunchKind.attach;

  bool get hasStarted => appId != null;

  LumideLaunchEvent event({int? exitCode, String? vmServiceUri}) {
    return LumideLaunchEvent(
      providerId: launchProviderFlutter,
      kind: kind,
      configurationId: configurationId,
      workspaceFolder: workspaceFolder,
      deviceId: switch (exitCode) {
        null => deviceId,
        _ => null,
      },
      exitCode: exitCode,
      vmServiceUri: vmServiceUri,
    );
  }

  /// Whether this is the launch Lumide names by [configurationId] and
  /// [kind], in [workspaceFolder] when both sides know the folder.
  bool matches({
    required LumideLaunchKind kind,
    required String configurationId,
    String? workspaceFolder,
  }) {
    if (kind != this.kind || configurationId != this.configurationId) {
      return false;
    }

    return switch ((workspaceFolder, this.workspaceFolder)) {
      (final asked?, final own?) => path.equals(asked, own),
      _ => true,
    };
  }

  /// Completes the request [message] answers; false when it answers none.
  bool handleResponse(Map<String, dynamic> message) {
    if (_restart case (:final id, errors: _) when message['id'] == id) {
      _restart = null;
    }
    return _requests.handle(message);
  }

  /// Notes an error the daemon logged, such as a compile error, for the
  /// restart in flight.
  void noteError(String message) => _restart?.errors.add(message);

  /// Sends [method] for this app to its daemon; cancelled before the app
  /// started.
  Future<MachineResult> request(
    String method, [
    Map<String, dynamic> parameters = const {},
  ]) {
    return _send(method, parameters).response;
  }

  /// Sends `app.restart`, with the errors the daemon logged until it
  /// answered. Use [reloads] to keep restarts one at a time.
  Future<MachineResult> restartApp({required bool fullRestart}) async {
    final (:id, :response) = _send(
      'app.restart',
      {'fullRestart': fullRestart, 'pause': false},
    );
    if (id == null) return response;

    final errors = <String>[];
    _restart = (id: id, errors: errors);
    final result = await response;
    return result.withErrors(errors);
  }

  ({int? id, Future<MachineResult> response}) _send(
    String method,
    Map<String, dynamic> parameters,
  ) {
    final appId = this.appId;
    if (appId == null) {
      return (
        id: null,
        response: Future.value(const MachineResult.cancelled())
      );
    }

    final (id, response) = _requests.create();
    final payload = [
      {
        'id': id,
        'method': method,
        'params': {'appId': appId, ...parameters},
      },
    ];
    process.write('${jsonEncode(payload)}\n');
    return (id: id, response: response);
  }

  /// Answers every request still waiting as cancelled, and stops listening.
  Future<void> dispose() async {
    _restart = null;
    _requests.cancelAll();
    reloads.cancelScheduled();
    final subscriptions = [stdoutSubscription, stderrSubscription];
    stdoutSubscription = null;
    stderrSubscription = null;
    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
  }
}
