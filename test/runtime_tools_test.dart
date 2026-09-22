import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  test('single-screen URLs preserve the VM authentication URI', () {
    const vm = 'ws://127.0.0.1:1234/a+b=/ws';
    final base = Uri.http('localhost:9100', '/', {'uri': vm}).toString();
    for (final page in DevToolsPage.values) {
      final url = Uri.parse(page.url(base));
      final route = Uri.parse(url.fragment);
      expect(route.path, '/${page.id}');
      expect(route.queryParameters, {'uri': vm, 'embedMode': 'one'});
    }
    final route = Uri.parse(Uri.parse(DevToolsPage.network.url(
      'http://localhost:9100/#/inspector?uri=ws%3A%2F%2Flocalhost%2Ftoken%2Fws',
    )).fragment);
    expect(route.queryParameters['uri'], 'ws://localhost/token/ws');
  });

  late _Context context;
  late _Vm service;
  late WidgetInspectorService inspector;
  setUp(() {
    context = _Context();
    service = _Vm();
    inspector = WidgetInspectorService(context, service);
  });
  tearDown(() => inspector.dispose());

  test('widget click reveals zero-based source and releases object group',
      () async {
    await inspector.handleDebugEvent(_inspect());
    expect(context.editor.locations.single,
        (uri: 'file:///project/lib/main.dart', line: 11, column: 6));
    expect(service.calls.last.$1, 'ext.flutter.inspector.disposeGroup');
  });

  test('supports JSON-encoded diagnostics and Windows creation paths',
      () async {
    service.selection = jsonEncode({
      'creationLocation': {
        'file': r'C:\project\lib\main.dart',
        'line': 1,
        'column': 1
      },
    });
    await inspector.handleDebugEvent(_inspect());
    expect(context.editor.locations.single,
        (uri: 'file:///C:/project/lib/main.dart', line: 0, column: 0));
  });

  test('ignores unrelated events, non-widgets, and missing source locations',
      () async {
    await inspector.handleDebugEvent(Event(kind: EventKind.kResume));
    expect(service.calls, isEmpty);
    service.selection = null;
    await inspector.handleDebugEvent(_inspect());
    service.selection = {
      'creationLocation': {'file': 'file:///x', 'line': 0}
    };
    await inspector.handleDebugEvent(_inspect());
    expect(context.editor.locations, isEmpty);
  });

  test('disposed sessions never navigate after a pending selection resolves',
      () async {
    final pending = Completer<Response>();
    service.pendingSelection = pending;
    final event = inspector.handleDebugEvent(_inspect());
    await Future<void>.delayed(Duration.zero);
    final disposal = inspector.dispose();
    pending.complete(Response.parse({'result': service.selection}));
    await event;
    await disposal;
    expect(service.calls.where((call) => call.$1.endsWith('disposeGroup')),
        isNotEmpty);
    expect(context.editor.locations, isEmpty);
  });

  test('selection bursts keep one request active and only resolve the latest',
      () async {
    final pending = Completer<Response>();
    service.pendingSelection = pending;
    final first = inspector.handleDebugEvent(_inspect());
    await Future<void>.delayed(Duration.zero);
    for (var index = 0; index < 100; index++) {
      unawaited(inspector.handleDebugEvent(_inspect()));
    }
    expect(
        service.calls
            .where((call) => call.$1.endsWith('getSelectedSummaryWidget'))
            .length,
        1);
    service.pendingSelection = null;
    pending.complete(Response.parse({'result': service.selection}));
    await first;
    expect(
        service.calls
            .where((call) => call.$1.endsWith('getSelectedSummaryWidget'))
            .length,
        2);
    expect(context.editor.locations.length, 1);
    expect(
        service.calls.where((call) => call.$1.endsWith('disposeGroup')).length,
        2);
  });

  test('stalled selections stop further RPCs and release late responses',
      () async {
    inspector = WidgetInspectorService(context, service,
        requestTimeout: const Duration(milliseconds: 10));
    final pending = Completer<Response>();
    service.pendingSelection = pending;
    await inspector.handleDebugEvent(_inspect());
    for (var index = 0; index < 20; index++) {
      await inspector.handleDebugEvent(_inspect());
    }
    expect(
        service.calls
            .where((call) => call.$1.endsWith('getSelectedSummaryWidget'))
            .length,
        1);
    expect(context.editor.locations, isEmpty);
    pending.complete(Response.parse({'result': service.selection}));
    await Future<void>.delayed(Duration.zero);
    expect(
        service.calls.where((call) => call.$1.endsWith('disposeGroup')).length,
        2);
  });

  test('expired inspector groups during hot restart do not disable inspection',
      () async {
    service.failCleanup = true;
    await inspector.handleDebugEvent(_inspect());
    service.failCleanup = false;
    await inspector.handleDebugEvent(_inspect());
    expect(context.editor.locations.length, 2);
  });

  test('toggles query current runtime state including external changes',
      () async {
    service.enabled = 'true';
    await inspector.togglePerformanceOverlay();
    expect(service.calls.last.$1, 'ext.flutter.showPerformanceOverlay');
    expect(service.calls.last.$2, {'enabled': 'false'});
    service.enabled = false;
    await inspector.togglePerformanceOverlay();
    expect(service.calls.last.$1, 'ext.flutter.showPerformanceOverlay');
    expect(service.calls.last.$2, {'enabled': 'true'});
  });

  test('widget selection configures project roots before enabling', () async {
    await inspector.toggleInspector();
    expect(
        service.calls.first.$1, 'ext.flutter.inspector.setPubRootDirectories');
    expect(service.calls.first.$2, {'arg0': '/project'});
    expect(service.calls.last.$1, 'ext.flutter.inspector.show');
    expect(service.calls.last.$2, {'enabled': 'true'});
    expect(context.window.messages.last, contains('Click a widget'));
  });

  test('missing extensions give an actionable message without RPC toggle',
      () async {
    service.extensions = [];
    await inspector.toggleInspector();
    expect(service.calls, isEmpty);
    expect(context.window.messages.single, contains('debug build'));
  });
}

Event _inspect() =>
    Event(kind: EventKind.kInspect, isolate: IsolateRef(id: 'main'));

class _Vm implements VmService {
  Object? enabled = 'false';
  bool failCleanup = false;
  Object? selection = {
    'creationLocation': {
      'file': 'file:///project/lib/main.dart',
      'line': 12,
      'column': 7
    },
  };
  Completer<Response>? pendingSelection;
  List<String> extensions = [
    'ext.flutter.inspector.show',
    'ext.flutter.inspector.getSelectedSummaryWidget',
    'ext.flutter.inspector.setPubRootDirectories',
    'ext.flutter.showPerformanceOverlay',
  ];
  final calls = <(String, Map<String, dynamic>?)>[];

  @override
  Future<VM> getVM() async => VM(isolates: [IsolateRef(id: 'main')]);

  @override
  Future<Isolate> getIsolate(String isolateId) async =>
      Isolate(extensionRPCs: extensions);

  @override
  Future<Response> callServiceExtension(String method,
      {String? isolateId, Map<String, dynamic>? args}) async {
    expect(isolateId, 'main');
    calls.add((method, args));
    if (failCleanup && method.endsWith('disposeGroup')) {
      throw RPCError(
          method, RPCErrorKind.kIsolateMustBeRunnable.code, 'Isolate exited');
    }
    if (method.endsWith('getSelectedSummaryWidget')) {
      if (pendingSelection case final pending?) return pending.future;
      return Response.parse({'result': selection}) ?? Response();
    }
    return Response.parse({'enabled': enabled}) ?? Response();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Context implements LumideContext {
  @override
  final _Editor editor = _Editor();
  @override
  final _Window window = _Window();
  @override
  final _Workspace workspace = _Workspace();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Editor implements LumideEditor {
  final locations = <({String uri, int line, int? column})>[];
  @override
  Future<void> revealRange(
      {required String uri, required int line, int? column}) async {
    locations.add((uri: uri, line: line, column: column));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Window implements LumideWindow {
  final messages = <String>[];
  @override
  Future<void> showMessage(String message,
      {MessageType type = MessageType.info, String? title}) async {
    messages.add(message);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Workspace implements LumideWorkspace {
  @override
  Future<String?> getRootUri() async => 'file:///project';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
