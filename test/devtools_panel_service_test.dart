import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';

void main() {
  late _Window window;
  late DevToolsPanelService panels;
  late List<Object> errors;
  setUp(() {
    window = _Window();
    errors = [];
    panels = DevToolsPanelService(window, (_, error) => errors.add(error),
        cleanupTimeout: const Duration(milliseconds: 20));
  });
  tearDown(() => panels.closeSession());

  Future<String?> url() async =>
      'http://localhost:9100/?uri=ws%3A%2F%2Flocalhost%2Fws';

  test('concurrent opens share one pane creation', () async {
    final create = Completer<LumideWebviewPanel>();
    window.pending = create;
    final opens =
        List.generate(20, (_) => panels.open(DevToolsPage.network, url));
    await Future<void>.delayed(Duration.zero);
    expect(window.created, 1);
    final panel = _Panel();
    create.complete(panel);
    await Future.wait(opens);
    await panels.closeSession();
    expect(panel.disposals, 1);
  });

  test('pane created after stop is closed without entering the next session',
      () async {
    final create = Completer<LumideWebviewPanel>();
    window.pending = create;
    final opening = panels.open(DevToolsPage.network, url);
    await Future<void>.delayed(Duration.zero);
    await panels.closeSession();
    window.pending = null;
    await panels.open(DevToolsPage.network, url);
    final stale = _Panel();
    create.complete(stale);
    await opening;
    expect(stale.disposals, 1);
    expect(window.panels.single.disposals, 0);
    await panels.closeSession();
    expect(window.panels.single.disposals, 1);
  });

  test('URL resolution from a stopped session cannot create a pane', () async {
    final resolved = Completer<String?>();
    final opening = panels.open(DevToolsPage.inspector, () => resolved.future);
    await panels.closeSession();
    resolved.complete(await url());
    await opening;
    expect(window.created, 0);
  });

  test('failed replacement retains ownership and can retry after recovery',
      () async {
    await panels.open(DevToolsPage.network, url);
    final first = window.panels.single..failDispose = true;
    await expectLater(panels.open(DevToolsPage.network, url), throwsStateError);
    expect(window.created, 1);
    first.failDispose = false;
    await panels.open(DevToolsPage.network, url);
    expect(first.disposals, 2);
    expect(window.created, 2);
  });

  test('repeated cleanup of a hung pane shares the original disposal',
      () async {
    await panels.open(DevToolsPage.memory, url);
    final stalled = Completer<void>();
    final panel = window.panels.single..pendingDispose = stalled;
    await panels.closeSession();
    await panels.closeSession();
    expect(panel.disposals, 1);
    stalled.complete();
    await Future<void>.delayed(Duration.zero);
    await panels.open(DevToolsPage.memory, url);
    expect(window.created, 2);
  });

  test('failed or hanging disposals do not block cleanup of other panes',
      () async {
    await panels.open(DevToolsPage.network, url);
    await panels.open(DevToolsPage.memory, url);
    await panels.open(null, url);
    window.panels.first.failDispose = true;
    final stalled = Completer<void>();
    window.panels[1].pendingDispose = stalled;
    await panels.closeSession();
    expect(window.panels.map((panel) => panel.disposals), [1, 1, 1]);
    expect(errors.length, 2);
    stalled.complete();
  });
}

class _Window implements LumideWindow {
  Completer<LumideWebviewPanel>? pending;
  int created = 0;
  final panels = <_Panel>[];
  @override
  Future<LumideWebviewPanel> createWebviewPanel(String viewType, String title,
      {Map<String, dynamic>? options}) async {
    created++;
    final waiting = pending;
    if (waiting != null) return waiting.future;
    final panel = _Panel();
    panels.add(panel);
    return panel;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Panel implements LumideWebviewPanel {
  int disposals = 0;
  bool failDispose = false;
  Completer<void>? pendingDispose;
  @override
  Future<void> dispose() async {
    disposals++;
    if (failDispose) throw StateError('Host refused disposal');
    await pendingDispose?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
