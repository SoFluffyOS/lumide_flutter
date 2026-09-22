import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';

/// Owns panes across asynchronous opens and run-session changes.
class DevToolsPanelService {
  DevToolsPanelService(
    this.window,
    this.onError, {
    this.cleanupTimeout = const Duration(seconds: 2),
    this.baseViewType = 'flutter.devtools',
    this.baseTitle = 'Flutter DevTools',
  });

  final LumideWindow window;
  final void Function(String, Object) onError;
  final Duration cleanupTimeout;
  final String baseViewType;
  final String baseTitle;
  final _panels = <DevToolsPage?, LumideWebviewPanel>{};
  final _opening = <DevToolsPage?, Future<void>>{};
  final _retired = <LumideWebviewPanel>{};
  final _closing = <LumideWebviewPanel, Future<bool>>{};
  int _generation = 0;

  Future<void> open(DevToolsPage? page, Future<String?> Function() resolveUrl) {
    final pending = _opening[page];
    if (pending != null) return pending;
    final operation = _open(page, resolveUrl, _generation);
    _opening[page] = operation;
    return operation.whenComplete(() {
      if (identical(_opening[page], operation)) _opening.remove(page);
    });
  }

  Future<void> _open(DevToolsPage? page, Future<String?> Function() resolveUrl,
      int generation) async {
    final url = await resolveUrl();
    if (url == null || generation != _generation) return;
    for (final retired in _retired.toList()) {
      if (!await _close(retired)) {
        throw StateError(
            'A previous DevTools pane could not be closed. Try again when the IDE responds.');
      }
    }
    final previous = _panels.remove(page);
    if (previous != null && !await _close(previous)) {
      throw StateError('The previous DevTools pane could not be closed.');
    }
    if (generation != _generation) return;
    final panel = await window.createWebviewPanel(
      switch (page) {
        null => baseViewType,
        _ => 'flutter.devtools.${page.id}'
      },
      switch (page) {
        null => baseTitle,
        _ => 'Flutter ${page.title}'
      },
      options: {'url': page?.url(url) ?? url},
    );
    if (generation != _generation) {
      await _close(panel);
      return;
    }
    _panels[page] = panel;
  }

  Future<void> closeSession() async {
    _generation++;
    _opening.clear();
    final panels = {..._panels.values, ..._retired};
    _panels.clear();
    await Future.wait(panels.map(_close));
  }

  Future<bool> _close(LumideWebviewPanel panel) {
    final pending = _closing[panel];
    if (pending != null) return _waitForClose(panel, pending);
    final close = _disposePanel(panel);
    _closing[panel] = close;
    unawaited(close.then((_) {
      if (identical(_closing[panel], close)) _closing.remove(panel);
    }));
    return _waitForClose(panel, close);
  }

  Future<bool> _waitForClose(LumideWebviewPanel panel, Future<bool> close) {
    return close.timeout(cleanupTimeout, onTimeout: () {
      _retired.add(panel);
      onError('Timed out closing DevTools pane',
          TimeoutException('Webview disposal'));
      return false;
    });
  }

  Future<bool> _disposePanel(LumideWebviewPanel panel) async {
    try {
      await panel.dispose();
      _retired.remove(panel);
      return true;
    } catch (error) {
      _retired.add(panel);
      onError('Failed to close DevTools pane', error);
      return false;
    }
  }
}
