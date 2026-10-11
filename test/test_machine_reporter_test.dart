import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/test_machine_reporter.dart';
import 'package:test/test.dart';

void main() {
  const root = '/project';
  const suitePath = '/project/test/math_test.dart';
  const suiteUri = 'file:///project/test/math_test.dart';

  late TestMachineReporter reporter;

  setUp(() => reporter = TestMachineReporter(projectRoot: root));

  void send(Map<String, Object?> event) => reporter.addLine(jsonEncode(event));

  void startSuite() {
    send({
      'type': 'suite',
      'suite': {'id': 0, 'platform': 'vm', 'path': suitePath},
    });
    send({
      'type': 'testStart',
      'test': {
        'id': 1,
        'name': 'loading $suitePath',
        'suiteID': 0,
        'groupIDs': <int>[],
      },
      'time': 0,
    });
    send({
      'type': 'testDone',
      'testID': 1,
      'result': 'success',
      'skipped': false,
      'hidden': true,
      'time': 5,
    });
    send({
      'type': 'group',
      'group': {'id': 2, 'suiteID': 0, 'parentID': null, 'name': ''},
    });
    send({
      'type': 'group',
      'group': {
        'id': 3,
        'suiteID': 0,
        'parentID': 2,
        'name': 'math',
        'line': 4,
        'url': suiteUri,
      },
    });
  }

  void startTest(int id, String name, {int line = 5}) {
    send({
      'type': 'testStart',
      'test': {
        'id': id,
        'name': name,
        'suiteID': 0,
        'groupIDs': [2, 3],
        'line': line,
        'url': suiteUri,
      },
      'time': 10,
    });
  }

  void finishTest(int id, String result, {bool skipped = false}) {
    send({
      'type': 'testDone',
      'testID': id,
      'result': result,
      'skipped': skipped,
      'hidden': false,
      'time': 25,
    });
  }

  Map<String, LumideTestResult> latest(List<LumideTestResult> results) => {
        for (final result in results) result.id: result,
      };

  test('maps suites, groups, and tests into a tree', () {
    startSuite();
    startTest(4, 'math adds');
    finishTest(4, 'success');
    reporter.finish();

    final results = latest(reporter.takePending());
    expect(results.keys, unorderedEquals(['suite:0', 'group:3', 'test:4']));

    final suite = results['suite:0'];
    expect(suite?.label, 'test/math_test.dart');
    expect(suite?.uri, suiteUri);
    expect(suite?.state, LumideTestState.passed);

    final group = results['group:3'];
    expect(group?.label, 'math');
    expect(group?.parentId, 'suite:0');
    expect(group?.line, 4);

    final test = results['test:4'];
    expect(test?.label, 'adds');
    expect(test?.parentId, 'group:3');
    expect(test?.state, LumideTestState.passed);
    expect(test?.line, 5);
    expect(test?.durationMs, 15);
    expect(reporter.summary, '1 passed');
  });

  test('sends groups before the tests inside them', () {
    startSuite();
    startTest(4, 'math adds');
    final order = [for (final result in reporter.takePending()) result.id];
    expect(order.indexOf('group:3'), lessThan(order.indexOf('test:4')));
    expect(order.indexOf('suite:0'), lessThan(order.indexOf('group:3')));
  });

  test('reports failures with messages and rolls them up', () {
    startSuite();
    startTest(4, 'math adds');
    startTest(5, 'math divides', line: 9);
    startTest(6, 'math skips');
    send({
      'type': 'error',
      'testID': 5,
      'error': 'Expected: 2\n  Actual: 3',
      'stackTrace': 'test/math_test.dart 9:5  main.<fn>',
      'isFailure': true,
    });
    finishTest(4, 'success');
    finishTest(5, 'failure');
    finishTest(6, 'success', skipped: true);
    reporter.finish();

    final results = latest(reporter.takePending());
    final failed = results['test:5'];
    expect(failed?.state, LumideTestState.failed);
    expect(failed?.message, contains('Actual: 3'));
    expect(failed?.message, contains('main.<fn>'));
    expect(results['test:6']?.state, LumideTestState.skipped);
    expect(results['group:3']?.state, LumideTestState.failed);
    expect(results['suite:0']?.state, LumideTestState.failed);
    expect(reporter.summary, '1 passed, 1 failed, 1 skipped');
    expect(reporter.hasFailures, isTrue);
  });

  test('marks a suite that fails to load as errored', () {
    send({
      'type': 'suite',
      'suite': {'id': 0, 'platform': 'vm', 'path': suitePath},
    });
    send({
      'type': 'testStart',
      'test': {
        'id': 1,
        'name': 'loading $suitePath',
        'suiteID': 0,
        'groupIDs': <int>[],
      },
      'time': 0,
    });
    send({
      'type': 'error',
      'testID': 1,
      'error': "Error: Undefined name 'x'.",
      'stackTrace': '',
      'isFailure': false,
    });
    send({
      'type': 'testDone',
      'testID': 1,
      'result': 'error',
      'skipped': false,
      'hidden': true,
      'time': 5,
    });
    reporter.finish();

    final suite = latest(reporter.takePending())['suite:0'];
    expect(suite?.state, LumideTestState.errored);
    expect(suite?.message, contains("Undefined name 'x'"));
  });

  test('errors tests left running when the run ends', () {
    startSuite();
    startTest(4, 'math hangs');
    reporter.finish();

    final test = latest(reporter.takePending())['test:4'];
    expect(test?.state, LumideTestState.errored);
    expect(test?.message, isNotNull);
  });

  test('ignores output that is not a reporter event', () {
    reporter
      ..addLine('Running "flutter pub get"...')
      ..addLine('{not json')
      ..addLine('[1, 2]');
    expect(reporter.takePending(), isEmpty);
  });

  test('maps result ids to targets for rerunning', () {
    startSuite();
    startTest(4, 'math adds');
    finishTest(4, 'success');

    final suite = reporter.targetOf('suite:0');
    expect(suite?.file, suitePath);
    expect(suite?.name, isNull);

    final group = reporter.targetOf('group:3');
    expect(group?.name, 'math');
    expect(group?.isGroup, isTrue);

    final test = reporter.targetOf('test:4');
    expect(test?.file, suitePath);
    expect(test?.name, 'math adds');
    expect(test?.isGroup, isFalse);

    expect(reporter.targetOf('group:2'), isNull, reason: 'root group');
    expect(reporter.targetOf('test:1'), isNull, reason: 'suite loading');
    expect(reporter.targetOf('test:99'), isNull);
    expect(reporter.targetOf('bogus'), isNull);
    expect(
      reporter.targets().keys,
      unorderedEquals(['suite:0', 'group:3', 'test:4']),
    );
  });

  test('sends plain lines, prints, and errors to output', () {
    final output = <String>[];
    reporter = TestMachineReporter(projectRoot: root, onOutput: output.add);
    startSuite();
    startTest(4, 'math adds');
    reporter.addLine('Running build hooks...');
    send({
      'type': 'print',
      'testID': 4,
      'messageType': 'print',
      'message': 'hello',
    });
    send({
      'type': 'error',
      'testID': 4,
      'error': 'Expected: 2',
      'stackTrace': 'math_test.dart 5:3',
    });
    reporter.addLine('   ');

    expect(output, [
      'Running build hooks...',
      '[math adds] hello',
      '[math adds] Expected: 2\n\nmath_test.dart 5:3',
    ]);
  });
}
