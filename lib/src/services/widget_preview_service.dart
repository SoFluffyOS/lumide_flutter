import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';

/// Hosts the SDK's preview web app in a regular, movable Lumide pane.
class WidgetPreviewService {
  WidgetPreviewService(this.context, this.projectService, this.sdkManager,
      {WidgetPreviewServer? server})
      : _server = server ?? WidgetPreviewServer();

  final LumideContext context;
  final ProjectService projectService;
  final SdkManager sdkManager;
  final WidgetPreviewServer _server;
  LumideWebviewPanel? _panel;
  Future<void>? _opening;
  String? _root;
  int _generation = 0;
  bool _disposed = false;
  bool _showingProgress = false;
  static const _progressItemId = 'flutter.widgetPreview.progress';

  Future<void> open() {
    if (_disposed) return Future.value();
    final pending = _opening;
    if (pending != null) return pending;
    final operation = _open(_generation);
    _opening = operation;
    return operation.whenComplete(() {
      if (identical(_opening, operation)) _opening = null;
    });
  }

  Future<void> _open(int generation) async {
    try {
      await _showProgress();
      final uri = await context.editor.getActiveDocumentUri();
      final root = switch ((uri, _root)) {
        (final documentUri?, _) =>
          await projectService.getWidgetPreviewRoot(documentUri),
        (null, final currentRoot?) => currentRoot,
        _ => await projectService.getWidgetPreviewRoot(),
      };
      if (!await sdkManager.supportsWidgetPreview(root)) {
        await _hideProgress();
        await context.window.showMessage(
          'Flutter Widget Preview requires Flutter 3.47 or newer.',
          type: MessageType.warning,
        );
        return;
      }
      if (_disposed || generation != _generation) return;
      final previous = _panel;
      _panel = null;
      await previous?.dispose();
      if (_disposed || generation != _generation) return;

      final panel = await context.window.createWebviewPanel(
        'flutter.widgetPreview',
        'Flutter Widget Preview',
        options: {'html': _loadingHtml, 'placement': 'right'},
      );
      if (_disposed || generation != _generation) {
        await panel.dispose();
        return;
      }
      _panel = panel;
      panel.onDidReceiveMessage((message) {
        if (!identical(_panel, panel) ||
            message is! Map ||
            message['lumideEvent'] != 'webviewDisposed') {
          return;
        }
        _panel = null;
        unawaited(stop());
      });

      final command = await sdkManager.getFlutterCommand(root);
      if (_disposed || generation != _generation) return;
      if (_root != root) {
        await _server.stop();
        if (_disposed || generation != _generation) return;
        _root = root;
      }
      _server.onExit = () {
        unawaited(stop());
      };
      final url = await _server.start(command, root);
      if (_disposed || generation != _generation) return;
      await panel.postMessage(url);
      await _hideProgress();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final panel = _panel;
      _panel = null;
      await Future.wait([_server.stop(), if (panel != null) panel.dispose()]);
      _root = null;
      await _hideProgress();
      await context.window
          .showMessage('Widget Preview: $error', type: MessageType.error);
    }
  }

  Future<void> stop() async {
    _generation++;
    _root = null;
    final panel = _panel;
    _panel = null;
    await Future.wait([
      _server.stop(),
      if (panel != null) panel.dispose(),
      _hideProgress(),
    ]);
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }

  Future<bool> isSupported() async {
    try {
      final uri = await context.editor.getActiveDocumentUri();
      final root = await projectService.getWidgetPreviewRoot(uri);
      return await sdkManager.supportsWidgetPreview(root);
    } catch (_) {
      return false;
    }
  }

  Future<void> _showProgress() async {
    if (_showingProgress) return;
    _showingProgress = true;
    await context.statusBar.createItem(
      id: _progressItemId,
      text: 'Widget Preview: Starting…',
      tooltip: 'Preparing Flutter Widget Preview',
      alignment: 'right',
      priority: 99,
    );
  }

  Future<void> _hideProgress() async {
    if (!_showingProgress) return;
    _showingProgress = false;
    await context.statusBar.disposeItem(_progressItemId);
  }
}

const _loadingHtml = '''
<!doctype html>
<html lang="en">
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root { color-scheme: light dark; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center;
      font: 14px system-ui, sans-serif; background: Canvas; color: CanvasText; }
    .status { display: flex; align-items: center; gap: 12px; }
    .spinner { width: 18px; height: 18px; border: 2px solid currentColor;
      border-right-color: transparent; border-radius: 50%;
      animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div class="status"><span class="spinner" aria-hidden="true"></span>
    <span>Starting Flutter Widget Preview…</span></div>
  <script>
    window.addEventListener('message', function(event) {
      if (typeof event.data === 'string') window.location.replace(event.data);
    });
  </script>
</body>
</html>
''';
