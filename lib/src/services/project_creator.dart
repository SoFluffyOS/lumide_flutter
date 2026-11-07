import 'dart:math' as math;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/project_templates.dart';

/// Runs `flutter create` with the SDK it is given; the arguments, folder
/// and result as [ProcessResult].
typedef FlutterRunner = Future<ProcessResult> Function(
  String projectRoot,
  List<String> arguments, {
  String? workingDirectory,
});

/// Creates projects from the templates `plugin.yaml` declares, as Lumide's
/// New Project dialog asks. Works without a workspace, as from the
/// Welcome screen.
class FlutterProjectCreator {
  const FlutterProjectCreator(this._runFlutter);

  final FlutterRunner _runFlutter;

  /// How many of the tool's last lines a failure shows.
  static const _failureLines = 4;

  /// Has Lumide send the templates' requests here.
  void register(LumideProjects projects) {
    for (final template in FlutterProjectTemplate.values) {
      projects.onCreate(template.id, create);
    }
  }

  Future<LumideProjectCreation> create(
    LumideProjectCreateRequest request,
  ) async {
    final template = FlutterProjectTemplate.byId(request.templateId);
    if (template == null) {
      throw Exception('Unknown Flutter template ${request.templateId}.');
    }

    final result = await _runFlutter(
      request.parent,
      template.createArgs(request),
      workingDirectory: request.parent,
    );
    if (result.exitCode != 0) {
      throw Exception(_failureOf(result));
    }

    return LumideProjectCreation(
      openFiles: [template.entryFile(request.name)],
    );
  }

  static String _failureOf(ProcessResult result) {
    final text = switch (result.stderr.trim()) {
      '' => result.stdout.trim(),
      final stderr => stderr,
    };
    if (text.isEmpty) {
      return 'flutter create exited with ${result.exitCode}.';
    }

    final lines = text.split('\n');
    return lines.sublist(math.max(0, lines.length - _failureLines)).join('\n');
  }
}
