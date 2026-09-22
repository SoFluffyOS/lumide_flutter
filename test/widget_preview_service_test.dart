import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';

void main() {
  test('opens a loading pane before the preview server is ready', () async {
    final context = _Context();
    final server = _Server();
    final projectService = _ProjectService(context);
    projectService.pendingRoot = Completer<void>();
    final service = WidgetPreviewService(
      context,
      projectService,
      _SdkManager(context),
      server: server,
    );
    addTearDown(service.dispose);

    final opening = service.open();
    await _waitFor(() => projectService.uris.isNotEmpty);
    expect(context.statusBar.text, 'Widget Preview: Starting…');
    projectService.pendingRoot?.complete();
    await _waitFor(() => context.window.panels.isNotEmpty);
    final panel = context.window.panels.single;
    expect(context.statusBar.alignment, 'right');
    expect(context.statusBar.priority, 99);
    expect(context.window.options.single['html'], contains('Starting Flutter'));
    expect(context.window.options.single['placement'], 'right');
    expect(panel.messages, isEmpty);
    await _waitFor(() => server.directory != null);
    expect(server.directory, '/workspace/app');

    server.ready.complete('http://localhost:1234/');
    await opening;
    expect(panel.messages, ['http://localhost:1234/']);
    expect(context.statusBar.text, isNull);

    context.editor.uri = null;
    await service.open();
    expect(projectService.uris, ['file:///workspace/app/lib/main.dart']);
    expect(server.directory, '/workspace/app');
    expect(context.window.panels.last.messages, ['http://localhost:1234/']);

    context.window.panels.last.closeFromHost();
    await _waitFor(() => server.stopCount > 0);
    expect(context.statusBar.text, isNull);
  });

  test('older Flutter SDK does not open a preview pane', () async {
    final context = _Context();
    final sdk = _SdkManager(context)..supported = false;
    final service = WidgetPreviewService(
      context,
      _ProjectService(context),
      sdk,
      server: _Server(),
    );
    addTearDown(service.dispose);

    expect(await service.isSupported(), isFalse);
    await service.open();
    expect(context.window.panels, isEmpty);
    expect(context.window.messages.single, contains('Flutter 3.47'));
    expect(context.statusBar.text, isNull);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

class _Context implements LumideContext {
  @override
  final _Editor editor = _Editor();
  @override
  final _Window window = _Window();
  @override
  final _StatusBar statusBar = _StatusBar();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Editor implements LumideEditor {
  String? uri = 'file:///workspace/app/lib/main.dart';
  @override
  Future<String?> getActiveDocumentUri() async => uri;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Window implements LumideWindow {
  final panels = <_Panel>[];
  final options = <Map<String, dynamic>>[];
  final messages = <String>[];

  @override
  Future<void> showMessage(String message,
      {MessageType type = MessageType.info, String? title}) async {
    messages.add(message);
  }

  @override
  Future<LumideWebviewPanel> createWebviewPanel(String viewType, String title,
      {Map<String, dynamic>? options}) async {
    this.options.add(options ?? {});
    final panel = _Panel();
    panels.add(panel);
    return panel;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StatusBar implements LumideStatusBar {
  String? text;
  String? alignment;
  int? priority;

  @override
  Future<void> createItem({
    required String id,
    required String text,
    String? tooltip,
    String? command,
    String? color,
    String? iconName,
    String? iconPath,
    String alignment = 'right',
    int priority = 0,
  }) async {
    this.text = text;
    this.alignment = alignment;
    this.priority = priority;
  }

  @override
  Future<void> disposeItem(String id) async => text = null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Panel implements LumideWebviewPanel {
  final messages = <Object>[];
  void Function(Object)? onMessage;
  void closeFromHost() => onMessage?.call({'lumideEvent': 'webviewDisposed'});
  @override
  void onDidReceiveMessage(void Function(Object message) callback) {
    onMessage = callback;
  }

  @override
  Future<void> postMessage(Object message) async => messages.add(message);
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProjectService extends ProjectService {
  _ProjectService(super.context);
  final uris = <String?>[];
  Completer<void>? pendingRoot;
  @override
  Future<String> getWidgetPreviewRoot([String? uri]) async {
    uris.add(uri);
    await pendingRoot?.future;
    return uri == null ? '/workspace/other' : '/workspace/app';
  }
}

class _SdkManager extends SdkManager {
  _SdkManager(super.context);
  bool supported = true;
  @override
  Future<bool> supportsWidgetPreview(String projectRoot) async => supported;
  @override
  Future<List<String>> getFlutterCommand(String projectRoot) async =>
      ['flutter'];
}

class _Server extends WidgetPreviewServer {
  final ready = Completer<String>();
  String? directory;
  int stopCount = 0;
  @override
  Future<String> start(List<String> command, String directory) {
    this.directory = directory;
    return ready.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}
