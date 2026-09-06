import 'dart:io';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/sdk/sdk.dart';
import 'package:path/path.dart' as path;

class FlutterSdkProvider {
  FlutterSdkProvider(this.context)
      : catalogService = FlutterReleaseCatalogService(context),
        detectionService = FlutterSdkDetectionService(context);

  final LumideContext context;
  final FlutterReleaseCatalogService catalogService;
  final FlutterSdkDetectionService detectionService;

  Future<void> register() async {
    context.sdks.onListAvailable(_listAvailable);
    context.sdks.onDiscover(_discover);
    context.sdks.onResolve(detectionService.resolve);
    context.sdks.onGetInstallPlan(_getInstallPlan);
    context.sdks.onValidate(_validate);
    await context.sdks.registerProvider(
      const LumideSdkProviderDescriptor(
        id: 'flutter',
        kind: LumideSdkKind.flutter,
        title: 'Flutter',
        capabilities: LumideSdkProviderCapabilities(
          catalog: true,
          discovery: true,
          resolution: true,
          validation: true,
          install: true,
        ),
        iconPath: 'assets/icon_flutter_solid.svg',
      ),
    );
  }

  Future<List<LumideSdkRelease>> _listAvailable(
    LumideSdkListRequest request,
  ) {
    if (request.providerId != 'flutter') return Future.value(const []);
    return catalogService.listAvailable(channel: request.channel);
  }

  Future<List<LumideSdkInstallation>> _discover(
    LumideSdkDiscoveryRequest request,
  ) {
    if (request.providerId != 'flutter') return Future.value(const []);
    return detectionService.discover(request.workspacePath);
  }

  Future<LumideSdkInstallPlan> _getInstallPlan(
    LumideSdkInstallPlanRequest request,
  ) async {
    final release = request.release;
    final archiveUri = release.archiveUri;
    final sha256 = release.sha256;
    final format = release.archiveFormat;
    if (request.providerId != 'flutter' ||
        archiveUri == null ||
        sha256 == null ||
        format == null) {
      throw StateError('Flutter release is not installable');
    }
    return LumideSdkInstallPlan.archive(
      releaseId: release.id,
      archiveUri: archiveUri,
      sha256: sha256,
      format: format,
      rootDirectory: release.archiveRootDirectory ?? 'flutter',
      executables: {
        'flutter': Platform.isWindows ? 'bin/flutter.bat' : 'bin/flutter',
        'dart': Platform.isWindows
            ? 'bin/cache/dart-sdk/bin/dart.exe'
            : 'bin/cache/dart-sdk/bin/dart',
      },
    );
  }

  Future<LumideSdkValidation> _validate(
    LumideSdkValidationRequest request,
  ) async {
    if (request.providerId != 'flutter') {
      return const LumideSdkValidation(
        state: LumideSdkValidationState.unavailable,
        message: 'Unknown Flutter SDK provider',
      );
    }
    final installation = request.installation;
    final declaredExecutable = installation.executables['flutter'];
    if (declaredExecutable == null) {
      return const LumideSdkValidation(
        state: LumideSdkValidationState.invalid,
        message: 'Flutter executable is not declared',
      );
    }
    final executable = path.isAbsolute(declaredExecutable)
        ? declaredExecutable
        : path.join(installation.rootPath, declaredExecutable);
    if (!await File(executable).exists()) {
      return LumideSdkValidation(
        state: LumideSdkValidationState.invalid,
        message: 'Flutter executable does not exist',
        details: [executable],
      );
    }
    try {
      final result = await Process.run(
        executable,
        ['--version', '--machine'],
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode == 0) {
        return LumideSdkValidation(
          state: LumideSdkValidationState.valid,
          message: 'Flutter ${installation.version}',
        );
      }
      return LumideSdkValidation(
        state: LumideSdkValidationState.invalid,
        message: 'Flutter executable returned ${result.exitCode}',
        details: [result.stderr.toString().trim()],
      );
    } catch (error) {
      return LumideSdkValidation(
        state: LumideSdkValidationState.invalid,
        message: 'Flutter validation failed',
        details: [error.toString()],
      );
    }
  }
}
