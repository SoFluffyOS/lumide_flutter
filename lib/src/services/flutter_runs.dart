import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/flutter_run.dart';

/// The Flutter apps running now, by the launch Lumide knows each by, oldest
/// first.
class FlutterRuns {
  final _runs = <FlutterRun>[];

  bool get isEmpty => _runs.isEmpty;

  bool get isNotEmpty => _runs.isNotEmpty;

  List<FlutterRun> get all => List.unmodifiable(_runs);

  /// The runs whose app started, so it can take requests.
  List<FlutterRun> get started =>
      List.unmodifiable(_runs.where((run) => run.hasStarted));

  FlutterRun? get first => _runs.firstOrNull;

  void add(FlutterRun run) => _runs.add(run);

  void remove(FlutterRun run) => _runs.remove(run);

  bool contains(FlutterRun run) => _runs.contains(run);

  /// The newest run of the launch Lumide names by [configurationId] and
  /// [kind], in [workspaceFolder] when it gives one.
  FlutterRun? find({
    required LumideLaunchKind kind,
    required String configurationId,
    String? workspaceFolder,
  }) {
    return _runs.reversed
        .where(
          (run) => run.matches(
            kind: kind,
            configurationId: configurationId,
            workspaceFolder: workspaceFolder,
          ),
        )
        .firstOrNull;
  }
}
