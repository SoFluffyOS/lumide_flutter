import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
import 'package:lumide_flutter/src/services/test_machine_reporter.dart';
import 'package:path/path.dart' as path;

/// Runs `flutter test --machine` and shows results in Lumide's Tests pane.
///
/// One run at a time: starting a new run stops the previous one.
class TestRunService {
  TestRunService(
    this.context,
    this.projectService,
    this.sdkManager,
    this.logService, {
    this.flushInterval = const Duration(milliseconds: 100),
  });

  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final LogService logService;

  /// How often results are sent to Lumide while tests run.
  final Duration flushInterval;

  _ActiveRun? _active;

  bool get isRunning => _active != null;

  /// Runs all tests in the current project.
  Future<void> runAll() => run();

  /// Runs the tests in the active editor's file, or in a file or folder
  /// passed by a menu as `uri`/`path`.
  Future<void> runFile([Map<String, dynamic>? args]) async {
    final target = _pathFromArgs(args) ?? await _activeDocumentPath();
    if (target == null) {
      await context.window.showMessage(
        'Open a test file to run its tests.',
        type: MessageType.warning,
      );
      return;
    }
    await run(target: target);
  }

  /// Runs tests for [target] (a file or folder), or the whole project.
  Future<void> run({String? target, List<String> toolArgs = const []}) async {
    await stop();

    final String root;
    try {
      root = await projectService.getProjectRoot(switch (target) {
        final value? => Uri.file(value).toString(),
        _ => null,
      });
    } catch (error) {
      await context.window.showMessage(
        'No Flutter project found to test.',
        type: MessageType.error,
      );
      logService.error('Could not find a project to test', error);
      return;
    }

    final relativeTarget = switch (target) {
      final value? when path.isWithin(root, value) =>
        path.relative(value, from: root),
      final value? => value,
      _ => null,
    };
    final title = switch (relativeTarget) {
      final value? => 'flutter test $value',
      _ => 'flutter test',
    };

    final LumideTestRun testRun;
    try {
      testRun = await context.tests.createRun(title: title);
    } catch (error) {
      await context.window.showMessage(
        'Running tests requires Lumide 0.23.0 or later.',
        type: MessageType.warning,
      );
      logService.error('Could not create a test run', error);
      return;
    }

    final SdkProcess process;
    try {
      process = await sdkManager.startFlutter(root, [
        'test',
        '--machine',
        ...toolArgs,
        if (relativeTarget != null) relativeTarget,
      ]);
    } catch (error) {
      await testRun.end(summary: 'Could not start flutter test: $error');
      logService.error('Could not start flutter test', error);
      return;
    }

    final active = _ActiveRun(
      process: process,
      testRun: testRun,
      reporter: TestMachineReporter(projectRoot: root),
    );
    _active = active;
    active.flushTimer = Timer.periodic(flushInterval, (_) => _flush(active));
    active.stdout = process.stdout
        .transform(const LineSplitter())
        .listen(active.reporter.addLine);
    active.stderr = process.stderr.listen(active.stderrOutput.write);
    unawaited(process.exitCode.then((code) => _finish(active, code)));
  }

  /// Stops the running tests, if any.
  Future<void> stop() async {
    final active = _active;
    if (active == null) return;
    active.cancelled = true;
    await active.process.kill();
    await active.done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => active.process.kill(force: true),
    );
  }

  Future<void> dispose() => stop();

  Future<void> _flush(_ActiveRun active) async {
    final results = active.reporter.takePending();
    if (results.isEmpty) return;
    try {
      await active.testRun.update(results);
    } catch (error) {
      logService.error('Could not send test results', error);
    }
  }

  Future<void> _finish(_ActiveRun active, int exitCode) async {
    active.flushTimer?.cancel();
    await active.stdout?.cancel();
    await active.stderr?.cancel();
    active.reporter.finish();
    await _flush(active);

    final stderrText = active.stderrOutput.toString().trim();
    if (stderrText.isNotEmpty) logService.warn('flutter test: $stderrText');
    final summary = switch ((active.cancelled, active.reporter.summary)) {
      (true, final counts) => 'Stopped. $counts',
      (false, '0 passed') when exitCode != 0 =>
        'flutter test exited with code $exitCode. $stderrText'.trim(),
      (false, final counts) => counts,
    };
    try {
      await active.testRun.end(summary: summary);
    } catch (error) {
      logService.error('Could not end the test run', error);
    }
    if (identical(_active, active)) _active = null;
    active.done.complete();
  }

  String? _pathFromArgs(Map<String, dynamic>? args) {
    if (projectService.pathFromMenuContext(args) case final menuPath?) {
      return menuPath;
    }
    final value = args?['path'] ?? args?['uri'];
    if (value is! String || value.isEmpty) return null;
    if (value.startsWith('file:')) return Uri.parse(value).toFilePath();
    return value;
  }

  Future<String?> _activeDocumentPath() async {
    try {
      final uri = await context.editor.getActiveDocumentUri();
      if (uri == null || uri.isEmpty) return null;
      if (uri.startsWith('file:')) return Uri.parse(uri).toFilePath();
      return uri;
    } catch (_) {
      return null;
    }
  }
}

class _ActiveRun {
  _ActiveRun({
    required this.process,
    required this.testRun,
    required this.reporter,
  });

  final SdkProcess process;
  final LumideTestRun testRun;
  final TestMachineReporter reporter;
  final StringBuffer stderrOutput = StringBuffer();
  final Completer<void> done = Completer<void>();
  Timer? flushTimer;
  StreamSubscription<String>? stdout;
  StreamSubscription<String>? stderr;
  bool cancelled = false;
}
