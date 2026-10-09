import 'dart:async';

import 'package:lumide_flutter/src/services/machine_requests.dart';

/// Sends `app.restart` for a reload or a full restart.
typedef AppRestartSender = Future<MachineResult> Function({
  required bool fullRestart,
});

/// Receives the outcome of every request that was actually sent, once.
typedef AppRestartResultHandler = FutureOr<void> Function(
  MachineResult result, {
  required bool fullRestart,
});

/// Serializes hot reloads and hot restarts.
///
/// flutter_tools rejects a restart while another one is in progress, so
/// requests run one at a time. A reload requested while another reload is
/// still waiting to start joins that waiting reload instead of queueing a
/// second one. [scheduleReload] debounces bursts such as "Save All".
class HotReloadController {
  HotReloadController({
    required AppRestartSender send,
    AppRestartResultHandler? onResult,
    this.debounce = const Duration(milliseconds: 200),
  })  : _send = send,
        _onResult = onResult;

  final AppRestartSender _send;
  final AppRestartResultHandler? _onResult;
  final Duration debounce;

  Future<void> _tail = Future.value();
  Future<MachineResult>? _waitingReload;
  Timer? _debounceTimer;

  Future<MachineResult> reload() {
    if (_waitingReload case final waiting?) return waiting;
    late final Future<MachineResult> reload;
    reload = _enqueue(
      fullRestart: false,
      onStart: () {
        if (identical(_waitingReload, reload)) _waitingReload = null;
      },
    );
    _waitingReload = reload;
    return reload;
  }

  Future<MachineResult> restart() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    return _enqueue(fullRestart: true);
  }

  /// Reloads once no further call arrives within [debounce].
  void scheduleReload() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(reload());
    });
  }

  void cancelScheduled() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  Future<MachineResult> _enqueue({
    required bool fullRestart,
    void Function()? onStart,
  }) {
    final previous = _tail;
    final completer = Completer<MachineResult>();
    _tail = completer.future.then<void>((_) {});
    unawaited(() async {
      await previous;
      onStart?.call();
      final result = await _sendSafely(fullRestart: fullRestart);
      try {
        await _onResult?.call(result, fullRestart: fullRestart);
      } catch (_) {
        // Reporting must never stall the queue.
      }
      completer.complete(result);
    }());
    return completer.future;
  }

  Future<MachineResult> _sendSafely({required bool fullRestart}) async {
    try {
      return await _send(fullRestart: fullRestart);
    } catch (error) {
      return MachineResult(code: -1, message: error.toString());
    }
  }
}
