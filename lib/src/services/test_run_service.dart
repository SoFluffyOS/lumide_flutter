import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
import 'package:lumide_flutter/src/services/test_machine_reporter.dart';
import 'package:lumide_flutter/src/services/test_selection.dart';
import 'package:path/path.dart' as path;

/// Runs `flutter test --machine` and shows results in Lumide's Tests pane.
///
/// Like JetBrains, different tests run side by side, and running tests that
/// are still running asks to stop and rerun them. Each run title writes to
/// its own output channel, and recent runs are remembered so the Tests pane
/// can run them, or tests inside them, again.
class TestRunService {
  TestRunService(
    this.context,
    this.projectService,
    this.sdkManager,
    this.logService, {
    this.flushInterval = const Duration(milliseconds: 100),
  });

  /// Runs remembered for rerunning from the Tests pane, as many as Lumide
  /// keeps.
  static const maxRememberedRuns = 10;

  /// Output channels kept for reuse by later runs with the same title.
  static const maxOutputChannels = 10;

  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final LogService logService;

  /// How often results and output are sent to Lumide while tests run.
  final Duration flushInterval;

  final Map<String, _ActiveRun> _active = {};
  final Map<String, _RunRecord> _records = {};
  final Map<String, LumideOutputChannel> _channels = {};

  bool get isRunning => _active.isNotEmpty;

  /// Runs all tests in the current project.
  Future<void> runAll() => run();

  /// Runs the tests in the active editor's file, or in a file or folder
  /// passed by a menu as `uri`/`path`.
  ///
  /// A `name` runs only the test or group with that full name; `kind: test`
  /// excludes tests whose names merely start with it.
  Future<void> runFile([Map<String, dynamic>? args]) async {
    final target = _pathFromArgs(args) ?? await _activeDocumentPath();
    if (target == null) {
      await context.window.showMessage(
        'Open a test file to run its tests.',
        type: MessageType.warning,
      );
      return;
    }
    final name = args?['name'];
    if (name is! String || name.isEmpty) {
      await run(target: target);
      return;
    }
    await _start(
      TestInvocation(
        files: [target],
        namePattern: testNamePattern(
          name,
          includeChildren: args?['kind'] != 'test',
        ),
      ),
      title: name,
    );
  }

  /// Runs tests for [target] (a file or folder), or the whole project.
  Future<void> run({String? target, List<String> toolArgs = const []}) =>
      _start(
        TestInvocation(files: [if (target case final value?) value]),
        toolArgs: toolArgs,
      );

  /// Runs a remembered run again, or the tests in it named by `testIds`.
  ///
  /// Called by Lumide's Tests pane with `{'runId': ..., 'testIds': [...]}`.
  Future<void> rerun([Map<String, dynamic>? args]) async {
    final runId = args?['runId'];
    final record = switch (runId) {
      final String id => _recordFor(id),
      _ => null,
    };
    if (record == null) {
      logService.warn('Cannot rerun tests: unknown run $runId');
      return;
    }
    final testIds = [
      for (final id in args?['testIds'] as List? ?? const [])
        if (id is String) id,
    ];
    if (testIds.isEmpty) {
      await _start(
        record.invocation,
        title: record.title,
        toolArgs: record.toolArgs,
      );
      return;
    }

    final targets = <TestTarget>[];
    for (final id in testIds) {
      final target = record.targetOf(id);
      if (target == null) {
        logService.warn('Cannot rerun unknown test $id');
        continue;
      }
      targets.add(target);
    }
    if (targets.isEmpty) return;
    await _start(
      invocationFor(targets),
      title: _titleFor(targets),
      toolArgs: record.toolArgs,
    );
  }

  /// Stops the run named by `runId`, or every running run without one.
  Future<void> stop([Map<String, dynamic>? args]) async {
    final runs = switch (args?['runId']) {
      final String runId => [
          if (_lookup(_active, runId) case final active?) active,
        ],
      _ => _active.values.toList(),
    };
    await Future.wait(runs.map(_stopRun));
  }

  Future<void> dispose() async {
    await stop();
    final channels = _channels.values.toList();
    _channels.clear();
    for (final channel in channels) {
      await _disposeChannel(channel);
    }
  }

  Future<void> _stopRun(_ActiveRun active) async {
    active.cancelled = true;
    await active.process.kill();
    await active.done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => active.process.kill(force: true),
    );
  }

  Future<void> _start(
    TestInvocation invocation, {
    String? title,
    List<String> toolArgs = const [],
  }) async {
    final firstFile = invocation.files.firstOrNull;
    final String root;
    try {
      root = await projectService.getProjectRoot(switch (firstFile) {
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

    final selection = invocation.arguments(root);
    final arguments = ['test', '--machine', ...toolArgs, ...selection];
    final runTitle = title ?? _defaultTitle(invocation, root);
    final key = [root, ...arguments].join('\n');
    if (!await _stopSameTests(key, runTitle)) return;
    final channelName = _freeChannelName(runTitle);
    final output = await _outputChannel(channelName);

    final LumideTestRun testRun;
    try {
      testRun = await context.tests.createRun(
        title: runTitle,
        output: output,
        runCommand: cmdFlutterRerunTests,
        stopCommand: cmdFlutterStopTests,
      );
    } catch (error) {
      await context.window.showMessage(
        'Running tests requires Lumide 0.23.0 or later.',
        type: MessageType.warning,
      );
      logService.error('Could not create a test run', error);
      return;
    }

    final outputBuffer = <String>['', '\$ flutter ${arguments.join(' ')}'];
    final reporter = TestMachineReporter(
      projectRoot: root,
      onOutput: outputBuffer.add,
    );
    _remember(
      testRun.id,
      _RunRecord(
        invocation: invocation,
        title: runTitle,
        toolArgs: toolArgs,
        reporter: reporter,
      ),
    );

    final SdkProcess process;
    try {
      process = await sdkManager.startFlutter(root, arguments);
    } catch (error) {
      outputBuffer.add('Could not start flutter test: $error');
      await _writeOutput(output, outputBuffer);
      await testRun.end(summary: 'Could not start flutter test: $error');
      logService.error('Could not start flutter test', error);
      return;
    }

    final active = _ActiveRun(
      key: key,
      channelName: channelName,
      process: process,
      testRun: testRun,
      reporter: reporter,
      output: output,
      outputBuffer: outputBuffer,
    );
    _active[testRun.id] = active;
    active.flushTimer = Timer.periodic(flushInterval, (_) => _flush(active));
    active.stdout = process.stdout
        .transform(const LineSplitter())
        .listen(active.reporter.addLine);
    active.stderr = process.stderr.listen((text) {
      active.stderrOutput.write(text);
      outputBuffer.add(text.trimRight());
    });
    unawaited(process.exitCode.then((code) => _finish(active, code)));
  }

  /// Asks to stop running tests with the same [key] before running them
  /// again. Returns false when the user keeps them running.
  Future<bool> _stopSameTests(String key, String title) async {
    final running = [
      for (final active in _active.values)
        if (active.key == key) active,
    ];
    if (running.isEmpty) return true;
    final bool confirmed;
    try {
      confirmed = await context.window.showConfirmDialog(
        '"$title" is still running. Stop it and run it again?',
        title: 'Stop and Rerun',
      );
    } catch (error) {
      logService.error('Could not confirm rerunning tests', error);
      return false;
    }
    if (!confirmed) return false;
    await Future.wait(running.map(_stopRun));
    return true;
  }

  /// A channel name for [title] that no running run writes to.
  String _freeChannelName(String title) {
    final busy = {for (final active in _active.values) active.channelName};
    var name = '$channelFlutterTests: $title';
    for (var copy = 2; busy.contains(name); copy++) {
      name = '$channelFlutterTests: $title ($copy)';
    }
    return name;
  }

  /// Reuses and clears the channel last used by [name], like rerunning in
  /// the same JetBrains tab, or creates one.
  Future<LumideOutputChannel?> _outputChannel(String name) async {
    final existing = _channels.remove(name);
    if (existing != null) {
      _channels[name] = existing;
      try {
        await existing.clear();
      } catch (error) {
        logService.error('Could not clear test output', error);
      }
      return existing;
    }

    final LumideOutputChannel channel;
    try {
      channel = await context.window.createOutputChannel(name);
    } catch (error) {
      logService.error('Could not create the test output channel', error);
      return null;
    }
    _channels[name] = channel;
    await _evictChannels();
    return channel;
  }

  Future<void> _evictChannels() async {
    final busy = {for (final active in _active.values) active.channelName};
    final idle = [
      for (final name in _channels.keys)
        if (!busy.contains(name)) name,
    ];
    var excess = _channels.length - maxOutputChannels;
    for (final name in idle) {
      if (excess <= 0) return;
      final channel = _channels.remove(name);
      if (channel != null) await _disposeChannel(channel);
      excess--;
    }
  }

  Future<void> _disposeChannel(LumideOutputChannel channel) async {
    try {
      await channel.dispose();
    } catch (error) {
      logService.error('Could not dispose test output', error);
    }
  }

  Future<void> _writeOutput(
    LumideOutputChannel? output,
    List<String> buffer,
  ) async {
    if (buffer.isEmpty) return;
    final text = buffer.join('\n');
    buffer.clear();
    if (output == null) return;
    try {
      await output.appendLine(text);
    } catch (error) {
      logService.error('Could not write test output', error);
    }
  }

  Future<void> _flush(_ActiveRun active) async {
    await _writeOutput(active.output, active.outputBuffer);
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

    final stderrText = active.stderrOutput.toString().trim();
    if (stderrText.isNotEmpty) logService.warn('flutter test: $stderrText');
    final summary = switch ((active.cancelled, active.reporter.summary)) {
      (true, final counts) => 'Stopped. $counts',
      (false, '0 passed') when exitCode != 0 =>
        'flutter test exited with code $exitCode. $stderrText'.trim(),
      (false, final counts) => counts,
    };
    active.outputBuffer.add(summary);
    await _flush(active);
    try {
      await active.testRun.end(summary: summary);
    } catch (error) {
      logService.error('Could not end the test run', error);
    }
    _records[active.testRun.id]?.compact();
    _active.remove(active.testRun.id);
    active.done.complete();
  }

  void _remember(String runId, _RunRecord record) {
    _records.remove(runId);
    _records[runId] = record;
    while (_records.length > maxRememberedRuns) {
      _records.remove(_records.keys.first);
    }
  }

  _RunRecord? _recordFor(String runId) => _lookup(_records, runId);

  /// Lumide may prefix run ids with the plugin id (`lumide_flutter:run-1`).
  T? _lookup<T>(Map<String, T> byRunId, String runId) {
    final direct = byRunId[runId];
    if (direct != null) return direct;
    final separator = runId.lastIndexOf(':');
    if (separator < 0) return null;
    return byRunId[runId.substring(separator + 1)];
  }

  String _defaultTitle(TestInvocation invocation, String root) {
    final relativeFiles = invocation.arguments(root);
    if (relativeFiles.isEmpty) return 'flutter test';
    return 'flutter test ${relativeFiles.join(' ')}';
  }

  String _titleFor(List<TestTarget> targets) {
    if (targets.length > 1) return '${targets.length} tests';
    final target = targets.single;
    return target.name ?? path.basename(target.file);
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

/// A run that can be started again from the Tests pane.
class _RunRecord {
  _RunRecord({
    required this.invocation,
    required this.title,
    required this.toolArgs,
    required TestMachineReporter reporter,
  }) : _reporter = reporter;

  final TestInvocation invocation;
  final String title;
  final List<String> toolArgs;
  TestMachineReporter? _reporter;
  Map<String, TestTarget>? _targets;

  TestTarget? targetOf(String resultId) =>
      _targets?[resultId] ?? _reporter?.targetOf(resultId);

  /// Keeps only the targets once the run ends, dropping reporter state.
  void compact() {
    final reporter = _reporter;
    if (reporter == null) return;
    _targets = reporter.targets();
    _reporter = null;
  }
}

class _ActiveRun {
  _ActiveRun({
    required this.key,
    required this.channelName,
    required this.process,
    required this.testRun,
    required this.reporter,
    required this.output,
    required this.outputBuffer,
  });

  /// The project root and arguments; runs with the same key run the same
  /// tests.
  final String key;
  final String channelName;
  final SdkProcess process;
  final LumideTestRun testRun;
  final TestMachineReporter reporter;
  final LumideOutputChannel? output;
  final List<String> outputBuffer;
  final StringBuffer stderrOutput = StringBuffer();
  final Completer<void> done = Completer<void>();
  Timer? flushTimer;
  StreamSubscription<String>? stdout;
  StreamSubscription<String>? stderr;
  bool cancelled = false;
}
