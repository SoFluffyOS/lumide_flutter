import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

/// Turns `flutter test --machine` events into Tests pane results.
///
/// Suites become top-level results, named groups nest under them, and tests
/// nest under their innermost group. Hidden tests (suite loading) are not
/// shown, but a suite that fails to load is marked errored with the error.
/// Group and suite states are rolled up from their tests by [finish].
class TestMachineReporter {
  TestMachineReporter({required this.projectRoot});

  final String projectRoot;

  final Map<int, _Suite> _suites = {};
  final Map<int, _Group> _groups = {};
  final Map<int, _Test> _tests = {};
  final List<LumideTestResult> _pending = [];
  int _passed = 0;
  int _failed = 0;
  int _skipped = 0;

  /// Results changed since the last call.
  List<LumideTestResult> takePending() {
    final results = List.of(_pending);
    _pending.clear();
    return results;
  }

  /// A one-line summary such as `12 passed, 1 failed`.
  String get summary => [
        '$_passed passed',
        if (_failed > 0) '$_failed failed',
        if (_skipped > 0) '$_skipped skipped',
      ].join(', ');

  bool get hasFailures => _failed > 0;

  /// Handles one stdout line. Lines that are not reporter events are ignored.
  void addLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) return;
    final Object? event;
    try {
      event = jsonDecode(trimmed);
    } on FormatException {
      return;
    }
    if (event is! Map) return;
    switch (event['type']) {
      case 'suite':
        _onSuite(event['suite']);
      case 'group':
        _onGroup(event['group']);
      case 'testStart':
        _onTestStart(event['test'], event['time']);
      case 'error':
        _onError(event);
      case 'testDone':
        _onTestDone(event);
    }
  }

  /// Rolls up group and suite states, and marks unfinished tests as errored
  /// (the process exited before they completed).
  void finish() {
    for (final test in _tests.values) {
      if (test.isDone || test.isHidden) continue;
      test.state = LumideTestState.errored;
      test.message ??= 'The test run ended before this test finished.';
      _failed++;
      _emitTest(test);
    }
    final groupStates = <int, List<LumideTestState>>{};
    final suiteStates = <int, List<LumideTestState>>{};
    for (final test in _tests.values) {
      if (test.isHidden) continue;
      suiteStates.putIfAbsent(test.suiteId, () => []).add(test.state);
      var groupId = test.groupId;
      while (groupId != null) {
        groupStates.putIfAbsent(groupId, () => []).add(test.state);
        groupId = _groups[groupId]?.parentId;
      }
    }
    for (final group in _groups.values) {
      if (group.isRoot) continue;
      final state = _rollUp(groupStates[group.id] ?? const []);
      _pending.add(_groupResult(group, state));
    }
    for (final suite in _suites.values) {
      final state = switch (suite.loadError) {
        null => _rollUp(suiteStates[suite.id] ?? const []),
        _ => LumideTestState.errored,
      };
      _pending.add(_suiteResult(suite, state));
    }
  }

  void _onSuite(Object? json) {
    if (json is! Map) return;
    final id = json['id'];
    final suitePath = json['path'];
    if (id is! int || suitePath is! String) return;
    final suite = _Suite(id: id, path: suitePath);
    _suites[id] = suite;
    _pending.add(_suiteResult(suite, LumideTestState.running));
  }

  void _onGroup(Object? json) {
    if (json is! Map) return;
    final id = json['id'];
    final suiteId = json['suiteID'];
    if (id is! int || suiteId is! int) return;
    final name = json['name'] as String? ?? '';
    final parentId = json['parentID'] as int?;
    final group = _Group(
      id: id,
      suiteId: suiteId,
      parentId: parentId,
      name: name,
      line: json['line'] as int?,
      url: json['url'] as String?,
    );
    _groups[id] = group;
    if (group.isRoot) return;
    _pending.add(_groupResult(group, LumideTestState.running));
  }

  void _onTestStart(Object? json, Object? time) {
    if (json is! Map) return;
    final id = json['id'];
    final suiteId = json['suiteID'];
    if (id is! int || suiteId is! int) return;
    final groupIds = [
      for (final groupId in json['groupIDs'] as List? ?? const [])
        if (groupId is int) groupId,
    ];
    final test = _Test(
      id: id,
      suiteId: suiteId,
      groupId: groupIds.lastOrNull,
      name: json['name'] as String? ?? '',
      line: (json['root_line'] ?? json['line']) as int?,
      url: (json['root_url'] ?? json['url']) as String?,
      startedAt: time is int ? time : 0,
    );
    _tests[id] = test;
    if (test.isHidden) return;
    _emitTest(test);
  }

  void _onError(Map<dynamic, dynamic> event) {
    final test = _tests[event['testID']];
    if (test == null) return;
    final error = event['error']?.toString() ?? '';
    final stackTrace = event['stackTrace']?.toString() ?? '';
    final details = [error, stackTrace.trim()].where((part) => part.isNotEmpty);
    final message = details.join('\n\n');
    test.message = switch (test.message) {
      final previous? => '$previous\n\n$message',
      _ => message,
    };
    if (!test.isHidden) return;
    final suite = _suites[test.suiteId];
    if (suite == null) return;
    suite.loadError = test.message;
    _pending.add(_suiteResult(suite, LumideTestState.errored));
  }

  void _onTestDone(Map<dynamic, dynamic> event) {
    final test = _tests[event['testID']];
    if (test == null) return;
    test.isDone = true;
    final time = event['time'];
    if (time is int) test.durationMs = time - test.startedAt;
    if (test.isHidden) return;

    final skipped = event['skipped'] == true;
    test.state = switch ((skipped, event['result'])) {
      (true, _) => LumideTestState.skipped,
      (false, 'success') => LumideTestState.passed,
      (false, 'failure') => LumideTestState.failed,
      _ => LumideTestState.errored,
    };
    switch (test.state) {
      case LumideTestState.passed:
        _passed++;
      case LumideTestState.skipped:
        _skipped++;
      case LumideTestState.failed:
      case LumideTestState.errored:
        _failed++;
      case LumideTestState.queued:
      case LumideTestState.running:
        break;
    }
    _emitTest(test);
  }

  /// The state of a suite or group from the states of the tests under it.
  LumideTestState _rollUp(List<LumideTestState> states) {
    final hasErrors = states.contains(LumideTestState.errored);
    if (hasErrors) return LumideTestState.errored;
    final hasFailures = states.contains(LumideTestState.failed);
    if (hasFailures) return LumideTestState.failed;
    final allSkipped = states.isNotEmpty &&
        states.every((state) => state == LumideTestState.skipped);
    if (allSkipped) return LumideTestState.skipped;
    return LumideTestState.passed;
  }

  void _emitTest(_Test test) {
    final group = _groups[test.groupId];
    final suite = _suites[test.suiteId];
    _pending.add(
      LumideTestResult(
        id: 'test:${test.id}',
        label: _shortName(test.name, group),
        state: test.state,
        parentId: _parentResultId(group, test.suiteId),
        uri: _fileUri(test.url) ?? _suiteUri(suite),
        line: test.line,
        message: test.message,
        durationMs: test.durationMs,
      ),
    );
  }

  LumideTestResult _groupResult(_Group group, LumideTestState state) {
    final parent = _groups[group.parentId];
    return LumideTestResult(
      id: 'group:${group.id}',
      label: _shortName(group.name, parent),
      state: state,
      parentId: _parentResultId(parent, group.suiteId),
      uri: _fileUri(group.url) ?? _suiteUri(_suites[group.suiteId]),
      line: group.line,
    );
  }

  LumideTestResult _suiteResult(_Suite suite, LumideTestState state) {
    return LumideTestResult(
      id: 'suite:${suite.id}',
      label: _relativePath(suite.path),
      state: state,
      uri: _suiteUri(suite),
      message: suite.loadError,
    );
  }

  String _parentResultId(_Group? group, int suiteId) {
    if (group == null || group.isRoot) return 'suite:$suiteId';
    return 'group:${group.id}';
  }

  /// Test names include their groups' names; drop the parent's prefix.
  String _shortName(String name, _Group? parent) {
    final prefix = parent?.name ?? '';
    if (prefix.isEmpty || !name.startsWith('$prefix ')) return name;
    return name.substring(prefix.length + 1);
  }

  String _relativePath(String suitePath) {
    if (!path.isAbsolute(suitePath)) return suitePath;
    if (!path.isWithin(projectRoot, suitePath)) return suitePath;
    return path.relative(suitePath, from: projectRoot);
  }

  String? _suiteUri(_Suite? suite) {
    if (suite == null) return null;
    final absolute = switch (path.isAbsolute(suite.path)) {
      true => suite.path,
      false => path.join(projectRoot, suite.path),
    };
    return Uri.file(absolute).toString();
  }

  String? _fileUri(String? url) {
    if (url == null || !url.startsWith('file:')) return null;
    return url;
  }
}

class _Suite {
  _Suite({required this.id, required this.path});

  final int id;
  final String path;
  String? loadError;
}

class _Group {
  _Group({
    required this.id,
    required this.suiteId,
    required this.parentId,
    required this.name,
    required this.line,
    required this.url,
  });

  final int id;
  final int suiteId;
  final int? parentId;
  final String name;
  final int? line;
  final String? url;

  /// Each suite has an unnamed root group.
  bool get isRoot => parentId == null && name.isEmpty;
}

class _Test {
  _Test({
    required this.id,
    required this.suiteId,
    required this.groupId,
    required this.name,
    required this.line,
    required this.url,
    required this.startedAt,
  });

  final int id;
  final int suiteId;
  final int? groupId;
  final String name;
  final int? line;
  final String? url;
  final int startedAt;
  LumideTestState state = LumideTestState.running;
  String? message;
  int? durationMs;
  bool isDone = false;

  /// Suite loading shows up as a test outside any group.
  bool get isHidden => groupId == null;
}
