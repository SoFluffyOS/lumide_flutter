import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Writes the framework errors a Flutter app posts as `Flutter.Error`
/// events to the Flutter output.
///
/// Once something turns `ext.flutter.inspector.structuredErrors` on, such as
/// DevTools or Lumide's agent tools, Flutter posts its errors as these
/// events instead of printing them, so without this they would vanish from
/// the output. The events only come while it is on, so nothing prints
/// twice.
class FlutterErrorRelay {
  FlutterErrorRelay(this._service, this._write);

  final VmService _service;
  final void Function(String text) _write;
  StreamSubscription<Event>? _subscription;

  /// The most properties a rendered error shows when the app gave no text.
  static const maxProperties = 10;

  Future<void> listen() async {
    _subscription = _service.onExtensionEvent.listen(handle);
    await _service.streamListen(EventStreams.kExtension);
  }

  void handle(Event event) {
    if (event.extensionKind != 'Flutter.Error') return;

    final text = render(event.extensionData?.data ?? const {});
    if (text.isEmpty) return;
    _write(text);
  }

  /// The error's text as Flutter would have printed it: its
  /// `renderedErrorText`, or else its description and first properties.
  static String render(Map<String, dynamic> error) {
    if (error['renderedErrorText'] case final String text
        when text.trim().isNotEmpty) {
      return text.trimRight();
    }

    final description = switch (error['description']) {
      final String description => description.trim(),
      _ => '',
    };
    final properties = switch (error['properties']) {
      final List properties => [
          for (final property in properties.take(maxProperties))
            if (_propertyLine(property) case final line?) line,
        ],
      _ => const <String>[],
    };
    return [
      if (description.isNotEmpty) description,
      ...properties,
    ].join('\n');
  }

  static String? _propertyLine(Object? property) {
    if (property is! Map) return null;

    final description = switch (property['description']) {
      final String description when description.trim().isNotEmpty =>
        description.trim(),
      _ => null,
    };
    if (description == null) return null;

    return switch (property['name']) {
      final String name when name.isNotEmpty && property['showName'] != false =>
        '$name: $description',
      _ => description,
    };
  }

  Future<void> dispose() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _service.dispose();
  }
}
