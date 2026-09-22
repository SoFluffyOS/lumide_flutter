import 'dart:async';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/sdk_manager.dart';
import 'package:test/test.dart';

void main() {
  for (final (version, supported) in [
    ('3.46.9', false),
    ('3.47.0', true),
    ('3.48.0-0.1.pre', true),
    ('4.0.0', true),
    ('Unknown', false),
  ]) {
    test('Widget Preview support for Flutter $version is $supported', () async {
      final sdk = _SdkManager(_Context())..version = version;
      expect(await sdk.supportsWidgetPreview('/project'), supported);
      expect(await sdk.supportsWidgetPreview('/project'), supported);
      expect(sdk.versionReads, 1);
      sdk.clearCache();
      expect(await sdk.supportsWidgetPreview('/project'), supported);
      expect(sdk.versionReads, 2);
    });
  }

  test('concurrent version checks share one request', () async {
    final sdk = _SdkManager(_Context())
      ..version = '3.47.0'
      ..pendingVersion = Completer<void>();
    final first = sdk.supportsWidgetPreview('/project');
    final second = sdk.supportsWidgetPreview('/project');
    await Future<void>.delayed(Duration.zero);
    expect(sdk.versionReads, 1);
    sdk.pendingVersion?.complete();
    expect(await Future.wait([first, second]), [true, true]);
  });

  test('timed out version process is terminated', () async {
    if (Platform.isWindows) return;
    final sdk = SdkManager(_Context(),
        versionCheckTimeout: const Duration(milliseconds: 30));
    final stopwatch = Stopwatch()..start();
    final version = await sdk.getSdkVersion(
      ['/bin/sh', '-c', 'exec sleep 5'],
    );
    expect(version, 'Unknown');
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

class _SdkManager extends SdkManager {
  _SdkManager(super.context);

  String version = 'Unknown';
  int versionReads = 0;
  Completer<void>? pendingVersion;

  @override
  Future<List<String>> getFlutterCommand(String projectRoot) async =>
      ['flutter'];

  @override
  Future<String> getSdkVersion(List<String> command,
      {String? workingDir}) async {
    versionReads++;
    await pendingVersion?.future;
    return version;
  }
}

class _Context implements LumideContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
