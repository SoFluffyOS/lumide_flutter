/// Debugs a `flutter test --start-paused` process, one at a time.
abstract interface class TestDebugger {
  /// Starts a debug session that [stop] ends. Returns false when another
  /// debug session or app run is in progress.
  Future<bool> beginTestDebugging({required Future<void> Function() stop});

  /// Connects the session to the test process's VM service.
  Future<void> attachTestVmService(String vmServiceUri);

  /// Ends the session after the test process exits.
  Future<void> endTestDebugging(int exitCode);
}
