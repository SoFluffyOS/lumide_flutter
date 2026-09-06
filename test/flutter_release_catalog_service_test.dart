import 'dart:convert';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/sdk/flutter_release_catalog_service.dart';
import 'package:test/test.dart';

void main() {
  group('parseFlutterReleaseManifest', () {
    test('filters channel, architecture, and malformed releases', () {
      final manifest = jsonEncode({
        'base_url':
            'https://storage.googleapis.com/flutter_infra_release/releases',
        'releases': [
          _release(
            version: '3.40.0',
            channel: 'stable',
            architecture: 'arm64',
            archive: 'stable/macos/flutter_macos_arm64_3.40.0-stable.zip',
            date: '2026-08-20T00:00:00Z',
          ),
          _release(
            version: '3.41.0',
            channel: 'master',
            architecture: 'arm64',
            archive: 'master/macos/flutter_macos_arm64.zip',
            date: '2026-08-21T00:00:00Z',
          ),
          _release(
            version: '3.39.0',
            channel: 'stable',
            architecture: 'x64',
            archive: 'stable/macos/flutter_macos_3.39.0-stable.zip',
            date: '2026-08-19T00:00:00Z',
          ),
          {
            ..._release(
              version: 'broken',
              channel: 'beta',
              architecture: 'arm64',
              archive: 'beta/macos/flutter.zip',
              date: '2026-08-22T00:00:00Z',
            ),
            'sha256': 'not-a-checksum',
          },
        ],
      });

      final releases = parseFlutterReleaseManifest(
        manifest,
        platform: 'macos',
        architecture: 'arm64',
      );

      expect(releases, hasLength(1));
      expect(releases.single.version, '3.40.0');
      expect(releases.single.channel, 'stable');
      expect(releases.single.archiveFormat, LumideSdkArchiveFormat.zip);
      expect(
        releases.single.archiveUri,
        'https://storage.googleapis.com/flutter_infra_release/releases/'
        'stable/macos/flutter_macos_arm64_3.40.0-stable.zip',
      );
      expect(releases.single.embeddedSdks.single.version, '3.10.0');
    });

    test('sorts newest first and detects Linux tar.xz archives', () {
      final manifest = jsonEncode({
        'base_url': 'https://example.test/releases/',
        'releases': [
          _release(
            version: '3.38.0',
            channel: 'stable',
            architecture: 'x64',
            archive: 'stable/linux/flutter_linux_3.38.0.tar.xz',
            date: '2026-07-01T00:00:00Z',
          ),
          _release(
            version: '3.39.0',
            channel: 'beta',
            architecture: 'x64',
            archive: 'beta/linux/flutter_linux_3.39.0.tar.xz',
            date: '2026-08-01T00:00:00Z',
          ),
        ],
      });

      final releases = parseFlutterReleaseManifest(
        manifest,
        platform: 'linux',
        architecture: 'x64',
      );

      expect(releases.map((release) => release.version), ['3.39.0', '3.38.0']);
      expect(
        releases.every(
          (release) => release.archiveFormat == LumideSdkArchiveFormat.tarXz,
        ),
        isTrue,
      );
    });

    test('rejects invalid manifest shapes', () {
      expect(
        parseFlutterReleaseManifest(
          '[]',
          platform: 'linux',
          architecture: 'x64',
        ),
        isEmpty,
      );
    });
  });
}

Map<String, Object> _release({
  required String version,
  required String channel,
  required String architecture,
  required String archive,
  required String date,
}) {
  return {
    'hash': 'hash-$version-$channel-$architecture',
    'channel': channel,
    'version': version,
    'dart_sdk_version': '3.10.0',
    'dart_sdk_arch': architecture,
    'release_date': date,
    'archive': archive,
    'sha256': 'a' * 64,
  };
}
