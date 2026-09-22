import 'dart:async';
import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:vm_service/vm_service.dart';

/// Flutter runtime controls and navigation from on-device widget selections.
class WidgetInspectorService {
  WidgetInspectorService(
    this.context,
    this.service, {
    this.requestTimeout = const Duration(seconds: 5),
    this.cleanupTimeout = const Duration(seconds: 2),
  });

  final LumideContext context;
  final VmService service;
  bool _disposed = false;
  int _selection = 0;
  bool _toggling = false;
  bool _unresponsive = false;
  final Duration requestTimeout;
  final Duration cleanupTimeout;
  final String _groupPrefix = 'lumide.${DateTime.now().microsecondsSinceEpoch}';
  final _groups = <(String, String)>{};
  final _releasing = <(String, String), Future<void>>{};
  Event? _pendingSelection;
  Future<void>? _selectionWorker;
  Future<void>? _disposing;

  Future<T> _request<T>(Future<T> response) async {
    try {
      return await response.timeout(requestTimeout);
    } on TimeoutException {
      // Future.timeout cannot cancel a VM RPC. Stop issuing more requests until
      // reconnect so a stalled connection cannot accumulate pending RPCs.
      _unresponsive = true;
      _pendingSelection = null;
      rethrow;
    }
  }

  Future<Response> _call(
    String extension, {
    required String isolateId,
    Map<String, dynamic>? args,
  }) =>
      _request(service.callServiceExtension(extension,
          isolateId: isolateId, args: args));

  Future<void> toggleInspector() => _toggle(
        'ext.flutter.inspector.show',
        'Widget selection',
        configureRoots: true,
      );

  Future<void> togglePerformanceOverlay() => _toggle(
        'ext.flutter.showPerformanceOverlay',
        'Performance overlay',
      );

  Future<void> _toggle(
    String extension,
    String label, {
    bool configureRoots = false,
  }) async {
    if (_disposed || _toggling) return;
    if (_unresponsive) {
      await context.window.showMessage(
          'Flutter VM service is not responding. Reconnect the app to use runtime tools.',
          type: MessageType.warning);
      return;
    }
    _toggling = true;
    try {
      final vm = await _request(service.getVM());
      for (final ref in vm.isolates ?? <IsolateRef>[]) {
        final id = ref.id;
        if (id == null) continue;
        final isolate = await _request(service.getIsolate(id));
        if (_disposed) return;
        final extensions = isolate.extensionRPCs ?? <String>[];
        if (!extensions.contains(extension)) continue;
        if (configureRoots &&
            extensions
                .contains('ext.flutter.inspector.setPubRootDirectories')) {
          final root = await context.workspace.getRootUri();
          if (_disposed) return;
          if (root != null) {
            final uri = Uri.tryParse(root);
            final rootPath = switch (uri) {
              final Uri uri when uri.scheme == 'file' => uri.toFilePath(),
              _ => root,
            };
            await _call(
              'ext.flutter.inspector.setPubRootDirectories',
              isolateId: id,
              args: {'arg0': rootPath},
            );
          }
        }
        if (_disposed) return;
        final state = await _call(extension, isolateId: id);
        final enabled = state.json?['enabled'];
        final next = enabled != true && enabled != 'true';
        if (_disposed) return;
        await _call(
          extension,
          isolateId: id,
          args: {'enabled': next.toString()},
        );
        if (_disposed) return;
        final message = switch ((configureRoots, next)) {
          (true, true) =>
            'Click a widget in the running app to open its Flutter source.',
          (_, true) => '$label enabled.',
          _ => '$label disabled.',
        };
        await context.window.showMessage(message);
        return;
      }
      await context.window.showMessage(
        '$label is not available yet. Use a Flutter debug build and wait for the app to start.',
        type: MessageType.warning,
      );
    } catch (error) {
      if (_disposed) return;
      await context.window.showMessage(
        'Could not toggle $label: $error',
        type: MessageType.error,
      );
    } finally {
      _toggling = false;
    }
  }

  Future<void> handleDebugEvent(Event event) {
    if (_disposed ||
        _unresponsive ||
        event.kind != EventKind.kInspect ||
        event.isolate?.id == null) {
      return Future.value();
    }
    _selection++;
    _pendingSelection = event;
    final running = _selectionWorker;
    if (running != null) return running;
    final worker = _drainSelections();
    _selectionWorker = worker;
    return worker.whenComplete(() {
      if (identical(_selectionWorker, worker)) _selectionWorker = null;
    });
  }

  Future<void> _drainSelections() async {
    while (!_disposed && !_unresponsive) {
      final event = _pendingSelection;
      _pendingSelection = null;
      if (event == null) return;
      await _resolveSelection(event, _selection);
    }
  }

  Future<void> _resolveSelection(Event event, int selection) async {
    final isolateId = event.isolate?.id;
    if (isolateId == null) return;
    final group = '$_groupPrefix.$selection';
    final key = (isolateId, group);
    try {
      final isolate = await _request(service.getIsolate(isolateId));
      if (_disposed || selection != _selection) return;
      if (!(isolate.extensionRPCs ?? <String>[])
          .contains('ext.flutter.inspector.getSelectedSummaryWidget')) {
        return;
      }
      _groups.add(key);
      final responseFuture = service.callServiceExtension(
        'ext.flutter.inspector.getSelectedSummaryWidget',
        isolateId: isolateId,
        args: {'objectGroup': group},
      );
      unawaited(responseFuture.then((_) async {
        if (_disposed || _unresponsive) {
          _groups.add(key);
          await _releaseGroup(key);
        }
      }, onError: (Object _) {}));
      final response = await _request(responseFuture);
      if (_disposed || selection != _selection) return;
      final raw = response.json?['result'];
      final node = switch (raw) {
        final String value => jsonDecode(value),
        _ => raw,
      };
      if (node is! Map) return;
      final location = node['creationLocation'];
      if (location is! Map) return;
      final file = location['file'];
      final line = location['line'];
      final column = location['column'];
      if (file is! String || line is! int || line < 1) return;
      var uri = Uri.tryParse(file);
      if (uri == null) return;
      if (uri.scheme == 'package') {
        final resolved = await _request(
            service.lookupResolvedPackageUris(isolateId, [file]));
        final files = resolved.uris;
        if (files == null || files.isEmpty || files.first == null) return;
        uri = Uri.tryParse(files.first ?? '');
      }
      if (uri == null) return;
      if (uri.scheme.isEmpty || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(file)) {
        uri =
            Uri.file(file, windows: RegExp(r'^[A-Za-z]:[\\/]').hasMatch(file));
      }
      if (uri.scheme != 'file' || _disposed || selection != _selection) return;
      await context.editor.revealRange(
        uri: uri.toString(),
        line: line - 1,
        column: switch (column) {
          final int value when value > 0 => value - 1,
          _ => 0
        },
      );
    } catch (_) {
      // Selections can expire during a hot restart or point to non-widget objects.
    } finally {
      if (_groups.contains(key)) await _releaseGroup(key);
    }
  }

  Future<void> _releaseGroup((String, String) key) {
    final pending = _releasing[key];
    if (pending != null) return pending;
    final release = _disposeGroup(key);
    _releasing[key] = release;
    return release.whenComplete(() {
      if (identical(_releasing[key], release)) _releasing.remove(key);
    });
  }

  Future<void> _disposeGroup((String, String) key) async {
    try {
      await service.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: key.$1,
        args: {'objectGroup': key.$2},
      ).timeout(cleanupTimeout);
      _groups.remove(key);
    } on RPCError {
      // A hot restart can remove the isolate and its inspector groups.
      _groups.remove(key);
    } catch (_) {
      // Retain the group for another cleanup attempt before disconnecting.
      _unresponsive = true;
      _pendingSelection = null;
    }
  }

  Future<void> dispose() {
    final pending = _disposing;
    if (pending != null) return pending;
    _disposed = true;
    _selection++;
    _pendingSelection = null;
    final disposal = _dispose();
    _disposing = disposal;
    return disposal;
  }

  Future<void> _dispose() async {
    try {
      await _selectionWorker?.timeout(cleanupTimeout);
    } catch (_) {
      // Still attempt group disposal while the VM transport is connected.
    }
    await Future.wait(_groups.toList().map(_releaseGroup));
  }
}
