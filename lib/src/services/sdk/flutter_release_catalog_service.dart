import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:path/path.dart' as path;

class FlutterReleaseCatalogService {
  FlutterReleaseCatalogService(this.context);

  final LumideContext context;

  List<LumideSdkRelease>? _cachedReleases;
  Future<List<LumideSdkRelease>>? _inFlight;

  Future<List<LumideSdkRelease>> listAvailable({String? channel}) async {
    final cached = _cachedReleases;
    if (cached != null) return _filterChannel(cached, channel);
    final inFlight = _inFlight ??= _load();
    try {
      final releases = await inFlight;
      _cachedReleases = releases;
      return _filterChannel(releases, channel);
    } finally {
      if (identical(_inFlight, inFlight)) _inFlight = null;
    }
  }

  void invalidate() {
    _cachedReleases = null;
  }

  Future<List<LumideSdkRelease>> _load() async {
    final storageDirectory = await context.workspace.getPluginStorageDir();
    final cachePath = path.join(storageDirectory, _cacheFileName);
    try {
      final response = await context.http.get(_manifestUri.toString());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Flutter release service returned HTTP ${response.statusCode}',
        );
      }
      final releases = parseFlutterReleaseManifest(
        response.body,
        platform: _platform,
        architecture: _hostArchitecture,
      );
      if (releases.isEmpty) {
        throw const FormatException('Flutter release manifest is empty');
      }
      await context.fs.writeString(cachePath, response.body);
      return releases;
    } catch (error) {
      if (!await context.fs.exists(cachePath)) rethrow;
      final cachedBody = await context.fs.readString(cachePath);
      final releases = parseFlutterReleaseManifest(
        cachedBody,
        platform: _platform,
        architecture: _hostArchitecture,
      );
      if (releases.isEmpty) rethrow;
      return releases.map((release) => release.copyWith(stale: true)).toList();
    }
  }

  List<LumideSdkRelease> _filterChannel(
    List<LumideSdkRelease> releases,
    String? channel,
  ) {
    if (channel == null || channel.isEmpty) return List.unmodifiable(releases);
    return List.unmodifiable(
      releases.where((release) => release.channel == channel),
    );
  }

  String get _platform => switch (Platform.operatingSystem) {
        'macos' => 'macos',
        'windows' => 'windows',
        _ => 'linux',
      };

  String get _hostArchitecture {
    final abi = Abi.current().toString().toLowerCase();
    return abi.contains('arm64') ? 'arm64' : 'x64';
  }

  Uri get _manifestUri => Uri.https(
        'storage.googleapis.com',
        '/flutter_infra_release/releases/releases_$_platform.json',
      );

  String get _cacheFileName => 'flutter_releases_$_platform.json';
}

List<LumideSdkRelease> parseFlutterReleaseManifest(
  String body, {
  required String platform,
  required String architecture,
}) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return const [];
  final baseUrl = decoded['base_url']?.toString();
  final rawReleases = decoded['releases'];
  if (baseUrl == null || rawReleases is! List) return const [];
  final releases = <LumideSdkRelease>[];
  for (final rawRelease in rawReleases) {
    if (rawRelease is! Map) continue;
    final release = _parseFlutterRelease(
      baseUrl,
      rawRelease,
      platform: platform,
      hostArchitecture: architecture,
    );
    if (release != null) releases.add(release);
  }
  releases.sort((left, right) {
    final byDate = (right.releaseDate ?? '').compareTo(left.releaseDate ?? '');
    if (byDate != 0) return byDate;
    return right.version.compareTo(left.version);
  });
  return releases;
}

LumideSdkRelease? _parseFlutterRelease(
  String baseUrl,
  Map raw, {
  required String platform,
  required String hostArchitecture,
}) {
  final version = raw['version']?.toString() ?? '';
  final channel = raw['channel']?.toString() ?? '';
  final archive = raw['archive']?.toString() ?? '';
  final sha256 = raw['sha256']?.toString() ?? '';
  if (version.isEmpty ||
      !const {'stable', 'beta'}.contains(channel) ||
      archive.isEmpty ||
      !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256)) {
    return null;
  }
  final architecture = _flutterReleaseArchitecture(raw, archive);
  if (architecture != hostArchitecture) return null;
  final archiveUri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/$'), '')}/')
      .resolve(archive)
      .toString();
  final dartVersion = raw['dart_sdk_version']?.toString() ?? 'Unknown';
  final hash = raw['hash']?.toString() ?? '';
  return LumideSdkRelease(
    id: hash.isNotEmpty
        ? hash
        : 'flutter-$version-$channel-$platform-$architecture',
    version: version,
    channel: channel,
    releaseDate: raw['release_date']?.toString(),
    archiveUri: archiveUri,
    sha256: sha256,
    archiveFormat: _flutterArchiveFormat(archive),
    archiveRootDirectory: 'flutter',
    platform: platform,
    architecture: architecture,
    embeddedSdks: [
      LumideEmbeddedSdk(
        kind: LumideSdkKind.dart,
        version: dartVersion,
        rootPath: 'bin/cache/dart-sdk',
        executables: {
          'dart': platform == 'windows' ? 'bin/dart.exe' : 'bin/dart',
        },
      ),
    ],
  );
}

LumideSdkArchiveFormat _flutterArchiveFormat(String archive) {
  if (archive.endsWith('.tar.xz')) return LumideSdkArchiveFormat.tarXz;
  if (archive.endsWith('.tar.gz') || archive.endsWith('.tgz')) {
    return LumideSdkArchiveFormat.tarGz;
  }
  return LumideSdkArchiveFormat.zip;
}

String _flutterReleaseArchitecture(Map release, String archive) {
  final declared = release['dart_sdk_arch']?.toString().toLowerCase();
  if (declared == 'arm64' || declared == 'aarch64') return 'arm64';
  if (declared == 'x64' || declared == 'x86_64') return 'x64';
  if (archive.toLowerCase().contains('arm64')) return 'arm64';
  return 'x64';
}
