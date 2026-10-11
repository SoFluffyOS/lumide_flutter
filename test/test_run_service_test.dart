import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
import 'package:lumide_flutter/src/services/test_debugger.dart';
import 'package:lumide_flutter/src/services/test_run_service.dart';
import 'package:test/test.dart';

void main() {
  late _Context context;
  late _SdkManager sdkManager;
  late TestRunService service;

  setUp(() {
    context = _Context();
    sdkManager = _SdkManager(context);
    service = TestRunService(
      context,
      _ProjectService(context),
      sdkManager,
      LogService((_) {}),
      flushInterval: const Duration(milliseconds: 5),
    );
  });

  test('runs flutter test --machine and reports results', () async {
    await service.run(target: '/project/test/a_test.dart');

    expect(sdkManager.arguments, ['test', '--machine', 'test/a_test.dart']);
    expect(context.tests.runs.single.title, 'flutter test test/a_test.dart');

    final process = sdkManager.process;
    process.emit({
      'type': 'suite',
      'suite': {'id': 0, 'path': '/project/test/a_test.dart'},
    });
    process.emit({
      'type': 'group',
      'group': {'id': 1, 'suiteID': 0, 'parentID': null, 'name': ''},
    });
    process.emit({
      'type': 'testStart',
      'test': {
        'id': 2,
        'name': 'works',
        'suiteID': 0,
        'groupIDs': [1],
      },
      'time': 0,
    });
    process.emit({
      'type': 'testDone',
      'testID': 2,
      'result': 'success',
      'skipped': false,
      'time': 3,
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.exit(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final run = context.tests.runs.single;
    final states = {
      for (final result in run.results) result.id: result.state,
    };
    expect(states['test:2'], LumideTestState.passed);
    expect(states['suite:0'], LumideTestState.passed);
    expect(run.summary, '1 passed');
    expect(service.isRunning, isFalse);
  });

  test('different tests run side by side', () async {
    await service.run(target: '/project/test/a_test.dart');
    final first = sdkManager.process;
    await service.run(target: '/project/test/b_test.dart');

    expect(first.killed, isFalse);
    expect(context.window.confirmations, isEmpty);
    expect(context.tests.runs, hasLength(2));
    expect(service.isRunning, isTrue);
  });

  test('running tests that are still running asks to stop them', () async {
    await service.run(target: '/project/test/a_test.dart');
    final first = sdkManager.process;

    context.window.confirmResult = false;
    await service.run(target: '/project/test/a_test.dart');
    expect(first.killed, isFalse);
    expect(context.tests.runs, hasLength(1));

    context.window.confirmResult = true;
    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 5),
      () => first.exit(-15),
    ));
    await service.run(target: '/project/test/a_test.dart');

    expect(context.window.confirmations, hasLength(2));
    expect(first.killed, isTrue);
    expect(context.tests.runs.first.summary, startsWith('Stopped.'));
    expect(context.tests.runs, hasLength(2));
  });

  test('stop with a run id stops only that run', () async {
    await service.run(target: '/project/test/a_test.dart');
    final first = sdkManager.process;
    await service.run(target: '/project/test/b_test.dart');
    final second = sdkManager.process;

    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 5),
      () => first.exit(-15),
    ));
    await service.stop({'runId': 'lumide_flutter:run-1'});

    expect(first.killed, isTrue);
    expect(second.killed, isFalse);
    expect(service.isRunning, isTrue);
  });

  Future<void> emitMathRun(_Process process) async {
    process
      ..emit({
        'type': 'suite',
        'suite': {'id': 0, 'path': '/project/test/math_test.dart'},
      })
      ..emit({
        'type': 'group',
        'group': {'id': 1, 'suiteID': 0, 'parentID': null, 'name': ''},
      })
      ..emit({
        'type': 'group',
        'group': {'id': 2, 'suiteID': 0, 'parentID': 1, 'name': 'math'},
      });
    for (final (id, name) in [(3, 'math adds'), (4, 'math adds one')]) {
      process
        ..emit({
          'type': 'testStart',
          'test': {
            'id': id,
            'name': name,
            'suiteID': 0,
            'groupIDs': [1, 2],
          },
          'time': 0,
        })
        ..emit({
          'type': 'testDone',
          'testID': id,
          'result': 'success',
          'skipped': false,
          'time': 1,
        });
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.exit(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('runs one test by name from a code lens', () async {
    await service.runFile({
      'uri': 'file:///project/test/math_test.dart',
      'name': 'math adds',
      'kind': 'test',
      'line': 5,
    });

    expect(sdkManager.arguments, [
      'test',
      '--machine',
      '--name',
      r'^math adds$',
      'test/math_test.dart',
    ]);
    final run = context.tests.runs.single;
    expect(run.title, 'math adds');
    expect(run.runCommand, 'flutter.rerunTests');
    expect(run.stopCommand, 'flutter.stopTests');
    expect(
        run.output, same(context.window.channels['Flutter Tests: math adds']));
  });

  test('a name without a kind also runs the tests inside a group', () async {
    await service.runFile({
      'uri': 'file:///project/test/math_test.dart',
      'name': 'math',
    });

    expect(sdkManager.arguments, contains(r'^math( |$)'));
  });

  test('reruns the whole run with the same scope', () async {
    await service.run(target: '/project/test/math_test.dart');
    await emitMathRun(sdkManager.process);

    await service.rerun({'runId': 'run-1', 'testIds': <String>[]});

    expect(sdkManager.arguments, ['test', '--machine', 'test/math_test.dart']);
    expect(context.tests.runs, hasLength(2));
    expect(context.tests.runs.last.title, 'flutter test test/math_test.dart');
  });

  test('reruns selected tests and groups by id', () async {
    await service.run();
    await emitMathRun(sdkManager.process);

    await service.rerun({
      'runId': 'lumide_flutter:run-1',
      'testIds': ['test:3', 'unknown', 'group:2'],
    });

    final arguments = sdkManager.arguments;
    expect(arguments.take(3), ['test', '--machine', '--name']);
    expect(arguments.last, 'test/math_test.dart');
    final pattern = RegExp(arguments[3]);
    expect(pattern.hasMatch('math adds'), isTrue);
    expect(pattern.hasMatch('math adds one'), isTrue, reason: 'in group');
    expect(context.tests.runs.last.title, '2 tests');
  });

  test('a single rerun test uses an exact name', () async {
    await service.run();
    await emitMathRun(sdkManager.process);

    await service.rerun({
      'runId': 'run-1',
      'testIds': ['test:3']
    });

    final pattern = RegExp(sdkManager.arguments[3]);
    expect(pattern.hasMatch('math adds'), isTrue);
    expect(pattern.hasMatch('math adds one'), isFalse);
    expect(context.tests.runs.last.title, 'math adds');
  });

  test('ignores reruns of unknown runs and tests', () async {
    await service.rerun({'runId': 'run-9', 'testIds': <String>[]});
    expect(context.tests.runs, isEmpty);

    await service.run();
    await emitMathRun(sdkManager.process);
    await service.rerun({
      'runId': 'run-1',
      'testIds': ['test:99']
    });
    expect(context.tests.runs, hasLength(1));
  });

  test('writes the command line, output, and summary to the run channel',
      () async {
    await service.run(target: '/project/test/math_test.dart');
    sdkManager.process
      ..emitLine('Resolving dependencies...')
      ..emitStderr('warning: slow');
    await emitMathRun(sdkManager.process);

    final channel = context
        .window.channels['Flutter Tests: flutter test test/math_test.dart'];
    final output = channel?.lines.join('\n');
    expect(output, contains(r'$ flutter test --machine test/math_test.dart'));
    expect(output, contains('Resolving dependencies...'));
    expect(output, contains('warning: slow'));
    expect(output, contains('2 passed'));
  });

  test('a rerun reuses and clears its channel; parallel runs get their own',
      () async {
    await service.run(target: '/project/test/math_test.dart');
    await emitMathRun(sdkManager.process);
    await service.rerun({'runId': 'run-1', 'testIds': <String>[]});
    await service.runFile({
      'uri': 'file:///project/test/math_test.dart',
      'name': 'flutter test test/math_test.dart',
    });

    final window = context.window;
    expect(window.created, 2);
    expect(window.channels.keys, [
      'Flutter Tests: flutter test test/math_test.dart',
      'Flutter Tests: flutter test test/math_test.dart (2)',
    ]);
    expect(
      window.channels.values.first.cleared,
      1,
      reason: 'the rerun starts with an empty channel',
    );
  });

  test('debugs one test file in the debugger', () async {
    final debugger = _Debugger();
    service.debugger = debugger;
    await service.runFile({
      'uri': 'file:///project/test/a_test.dart',
      'name': 'adds',
      'kind': 'test',
    }, true);

    expect(sdkManager.arguments, [
      'test',
      '--machine',
      '--start-paused',
      '--name',
      r'^adds$',
      'test/a_test.dart',
    ]);
    final run = context.tests.runs.single;
    expect(run.debugCommand, 'flutter.debugTests');

    final process = sdkManager.process;
    process.emitLine(
      '[{"event":"test.startedProcess",'
      '"params":{"vmServiceUri":"http://127.0.0.1:8181/token=/"}}]',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(debugger.attached, ['http://127.0.0.1:8181/token=/']);
    expect(context.window.channels.values.single.lines.join(),
        isNot(contains('startedProcess')));

    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 5),
      () => process.exit(-15),
    ));
    await debugger.stop?.call();
    expect(process.killed, isTrue);
    expect(debugger.ended, [-15]);
  });

  test('debugging needs one test file and a free debugger', () async {
    final debugger = _Debugger();
    service.debugger = debugger;

    await service.runFile({'uri': 'file:///project/test'}, true);
    expect(context.window.messages.single, contains('one test file'));

    debugger.isBusy = true;
    await service.runFile({'uri': 'file:///project/test/a_test.dart'}, true);
    expect(context.tests.runs, isEmpty);
  });

  test('a coverage run sends its own lcov report', () async {
    const report = '/project/.dart_tool/lumide_flutter/coverage-0.info';
    context.fs.files[report] = 'stale';
    await service.runWithCoverage();

    expect(sdkManager.arguments, [
      'test',
      '--machine',
      '--coverage-path=$report',
      '--coverage',
    ]);
    expect(context.fs.files[report], isEmpty);
    final run = context.tests.runs.single;
    expect(run.title, 'flutter test --coverage');
    expect(run.debugCommand, isNull);

    context.fs.files[report] =
        'SF:lib/math.dart\nDA:1,1\nDA:2,1\nDA:3,1\nDA:4,0\nend_of_record\n';
    sdkManager.process.exit(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(run.coverage?.single.uri, 'file:///project/lib/math.dart');
    expect(run.coverage?.single.uncoveredLines, [4]);
    expect(run.summary, '0 passed, 75% covered');
  });

  test('stopping a debug session before the run starts stops it', () async {
    final debugger = _Debugger();
    service.debugger = debugger;
    final window = context.window;
    window.onCreateChannel = () async => debugger.stop?.call();

    await service.runFile({'uri': 'file:///project/test/a_test.dart'}, true);

    expect(context.tests.runs.single.summary, 'Stopped.');
    expect(debugger.ended, [-1]);
    expect(sdkManager.arguments, isEmpty);
  });
}

class _Debugger implements TestDebugger {
  bool isBusy = false;
  Future<void> Function()? stop;
  final attached = <String>[];
  final ended = <int>[];

  @override
  Future<bool> beginTestDebugging({
    required Future<void> Function() stop,
  }) async {
    if (isBusy) return false;
    this.stop = stop;
    return true;
  }

  @override
  Future<void> attachTestVmService(String vmServiceUri) async =>
      attached.add(vmServiceUri);

  @override
  Future<void> endTestDebugging(int exitCode) async => ended.add(exitCode);
}

class _Process implements SdkProcess {
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();
  final _exit = Completer<int>();
  bool killed = false;

  void emit(Map<String, Object?> event) =>
      _stdout.add('${jsonEncode(event)}\n');

  void emitLine(String line) => _stdout.add('$line\n');

  void emitStderr(String text) => _stderr.add(text);

  void exit(int code) {
    if (_exit.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(code);
  }

  @override
  Stream<String> get stdout => _stdout.stream;

  @override
  Stream<String> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(String text) {}

  @override
  Future<void> kill({bool force = false}) async => killed = true;
}

class _SdkManager extends SdkManager {
  _SdkManager(super.context);

  late _Process process;
  List<String> arguments = const [];

  @override
  Future<SdkProcess> startFlutter(
    String projectRoot,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    this.arguments = arguments;
    return process = _Process();
  }
}

class _ProjectService extends ProjectService {
  _ProjectService(super.context);

  @override
  Future<String> getProjectRoot([String? uri]) async => '/project';
}

class _Run implements LumideTestRun {
  _Run(
    this.id,
    this.title, {
    this.output,
    this.runCommand,
    this.debugCommand,
    this.stopCommand,
  });

  @override
  final String id;
  final String title;
  final LumideOutputChannel? output;
  final String? runCommand;
  final String? debugCommand;
  final String? stopCommand;
  final results = <LumideTestResult>[];
  List<LumideFileCoverage>? coverage;
  String? summary;

  @override
  Future<void> update(List<LumideTestResult> results) async =>
      this.results.addAll(results);

  @override
  Future<void> setCoverage(List<LumideFileCoverage> files) async =>
      coverage = files;

  @override
  Future<void> end({String? summary}) async => this.summary = summary;
}

class _Tests implements LumideTests {
  final runs = <_Run>[];

  @override
  Future<LumideTestRun> createRun({
    required String title,
    LumideOutputChannel? output,
    String? runCommand,
    String? debugCommand,
    String? stopCommand,
  }) async {
    final run = _Run(
      'run-${runs.length + 1}',
      title,
      output: output,
      runCommand: runCommand,
      debugCommand: debugCommand,
      stopCommand: stopCommand,
    );
    runs.add(run);
    return run;
  }
}

class _Channel implements LumideOutputChannel {
  _Channel(this.id);

  final lines = <String>[];
  int cleared = 0;
  bool disposed = false;

  @override
  final String id;

  @override
  Future<void> appendLine(String value) async => lines.add(value);

  @override
  Future<void> clear() async {
    cleared++;
    lines.clear();
  }

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Window implements LumideWindow {
  final channels = <String, _Channel>{};
  final confirmations = <String>[];
  final messages = <String>[];
  bool confirmResult = true;
  int created = 0;
  Future<void> Function()? onCreateChannel;

  @override
  Future<LumideOutputChannel> createOutputChannel(
    String name, {
    int? maxEntries,
  }) async {
    created++;
    await onCreateChannel?.call();
    return channels[name] = _Channel('channel-$created');
  }

  @override
  Future<void> showMessage(
    String message, {
    MessageType type = MessageType.info,
    String? title,
  }) async =>
      messages.add(message);

  @override
  Future<bool> showConfirmDialog(String message, {String? title}) async {
    confirmations.add(message);
    return confirmResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fs implements LumideFileSystem {
  final files = <String, String>{};

  @override
  Future<String> readString(String path) async =>
      files[path] ?? (throw StateError('missing $path'));

  @override
  Future<void> writeString(String path, String content) async =>
      files[path] = content;

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Context implements LumideContext {
  @override
  final _Fs fs = _Fs();

  @override
  final _Tests tests = _Tests();

  @override
  final _Window window = _Window();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
