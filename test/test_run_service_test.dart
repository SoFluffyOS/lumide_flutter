import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/log_service.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:lumide_flutter/src/services/sdk_process.dart';
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

  test('a new run stops the previous one', () async {
    await service.run();
    final first = sdkManager.process;

    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 5),
      () => first.exit(-15),
    ));
    await service.run();

    expect(first.killed, isTrue);
    expect(context.tests.runs.first.summary, startsWith('Stopped.'));
    expect(context.tests.runs, hasLength(2));
  });
}

class _Process implements SdkProcess {
  final _stdout = StreamController<String>();
  final _stderr = StreamController<String>();
  final _exit = Completer<int>();
  bool killed = false;

  void emit(Map<String, Object?> event) =>
      _stdout.add('${jsonEncode(event)}\n');

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
  _Run(this.title);

  final String title;
  final results = <LumideTestResult>[];
  String? summary;

  @override
  String get id => title;

  @override
  Future<void> update(List<LumideTestResult> results) async =>
      this.results.addAll(results);

  @override
  Future<void> end({String? summary}) async => this.summary = summary;
}

class _Tests implements LumideTests {
  final runs = <_Run>[];

  @override
  Future<LumideTestRun> createRun({required String title}) async {
    final run = _Run(title);
    runs.add(run);
    return run;
  }
}

class _Context implements LumideContext {
  @override
  final _Tests tests = _Tests();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
