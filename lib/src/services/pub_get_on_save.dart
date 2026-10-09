import 'dart:async';

import 'package:path/path.dart' as path;

/// Runs `pub get` for a package after its `pubspec.yaml` is saved.
///
/// Saves are debounced per package. While `pub get` runs for a package,
/// further saves queue at most one follow-up run.
class PubGetOnSave {
  PubGetOnSave({
    required Future<bool> Function() isEnabled,
    required Future<void> Function(String packageRoot) pubGet,
    this.debounce = const Duration(milliseconds: 500),
  })  : _isEnabled = isEnabled,
        _pubGet = pubGet;

  final Future<bool> Function() _isEnabled;
  final Future<void> Function(String packageRoot) _pubGet;
  final Duration debounce;

  final Map<String, Timer> _timers = {};
  final Set<String> _running = {};
  final Set<String> _rerun = {};
  bool _disposed = false;

  void handleSave(String uri) {
    final packageRoot = _packageRootFor(uri);
    if (_disposed || packageRoot == null) return;

    _timers.remove(packageRoot)?.cancel();
    _timers[packageRoot] = Timer(debounce, () {
      _timers.remove(packageRoot);
      unawaited(_run(packageRoot));
    });
  }

  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _run(String packageRoot) async {
    if (_running.contains(packageRoot)) {
      _rerun.add(packageRoot);
      return;
    }
    if (!await _isEnabled()) return;

    _running.add(packageRoot);
    try {
      do {
        _rerun.remove(packageRoot);
        await _pubGet(packageRoot);
      } while (_rerun.contains(packageRoot) && !_disposed);
    } catch (_) {
      // pubGet reports its own failures.
    } finally {
      _running.remove(packageRoot);
      _rerun.remove(packageRoot);
    }
  }

  static String? _packageRootFor(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme != 'file') return null;
    final filePath = parsed.toFilePath();
    if (path.basename(filePath) != 'pubspec.yaml') return null;
    return path.dirname(filePath);
  }
}
