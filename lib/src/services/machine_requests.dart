import 'dart:async';

/// Result of a `flutter run --machine` request.
///
/// [code] follows flutter_tools' `OperationResult`: `0` means success.
/// Transport errors (for example "hot restart already in progress") are
/// reported with a non-zero code and the error text as [message].
class MachineResult {
  const MachineResult({
    required this.code,
    required this.message,
    this.cancelled = false,
  });

  /// The request never got an answer because the app stopped first.
  const MachineResult.cancelled()
      : code = -1,
        message = 'The Flutter app is no longer running.',
        cancelled = true;

  final int code;
  final String message;
  final bool cancelled;

  bool get isSuccess => code == 0;

  factory MachineResult.fromResponse(Map<String, dynamic> response) {
    if (response['error'] case final Object error) {
      return MachineResult(code: -1, message: error.toString());
    }
    return switch (response['result']) {
      {'code': final num code, 'message': final String message} =>
        MachineResult(code: code.toInt(), message: message),
      {'code': final num code} =>
        MachineResult(code: code.toInt(), message: ''),
      _ => const MachineResult(code: 0, message: ''),
    };
  }
}

/// Matches `flutter run --machine` responses to the requests that caused them.
class MachineRequests {
  int _lastId = 0;
  final Map<int, Completer<MachineResult>> _pending = {};

  /// Allocates a request id and a future that completes with its response.
  (int, Future<MachineResult>) create() {
    final id = ++_lastId;
    final completer = Completer<MachineResult>();
    _pending[id] = completer;
    return (id, completer.future);
  }

  /// Completes the matching request. Returns false when [message] is not a
  /// response to a tracked request.
  bool handle(Map<String, dynamic> message) {
    if (message.containsKey('event')) return false;
    final id = switch (message['id']) {
      final num id => id.toInt(),
      _ => null,
    };
    if (id == null) return false;
    final completer = _pending.remove(id);
    if (completer == null) return false;
    completer.complete(MachineResult.fromResponse(message));
    return true;
  }

  /// Resolves every outstanding request as cancelled, e.g. when the process
  /// exits before answering.
  void cancelAll() {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      completer.complete(const MachineResult.cancelled());
    }
  }

  void reset() {
    cancelAll();
    _lastId = 0;
  }
}
