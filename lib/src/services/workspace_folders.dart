import 'package:path/path.dart' as path;

/// Launch configuration argument naming the workspace folder a
/// configuration runs in.
///
/// Lumide sends `workspaceFolder` on launch configurations of workspaces of
/// several folders, but `lumide_api` 1.12.0 does not read it yet. The plugin
/// keeps the folder in the configuration's arguments, which round-trip, so
/// that a launch request knows where to run. A `${workspaceFolder}` value is
/// resolved by Lumide at launch time.
const String workspaceFolderArgument = 'workspaceFolder';

/// Launch configuration argument keeping a relative `launch.json` target, so
/// it can be resolved against the project of the configuration's folder.
const String relativeTargetArgument = 'relativeTarget';

/// The workspace folder in [arguments], or null when it is missing or still
/// holds an unresolved variable (older Lumide versions).
String? workspaceFolderOf(Map<dynamic, dynamic>? arguments) {
  return absolutePathOrNull(arguments?[workspaceFolderArgument]);
}

/// [value] when it is a non-empty absolute path without variables.
String? absolutePathOrNull(Object? value) {
  if (value is! String || value.isEmpty || value.contains(r'${')) return null;
  if (!path.isAbsolute(value)) return null;
  return path.normalize(value);
}

/// Whether [filePath] is [folder] or inside it.
bool isInFolder(String folder, String filePath) {
  return path.equals(folder, filePath) || path.isWithin(folder, filePath);
}

/// The [paths] inside [folder], or all of them when [folder] is null.
List<String> pathsInFolder(Iterable<String> paths, String? folder) {
  if (folder == null) return paths.toList();
  return [
    for (final candidate in paths)
      if (isInFolder(folder, candidate)) candidate,
  ];
}

/// The launch [targets] to list under [folder]: the ones inside it, or all
/// of them when [folder] is null.
///
/// The first folder also lists [selectedTarget] when it lies outside every
/// folder of [knownFolders], such as a custom target outside the workspace,
/// so that it stays selectable.
List<String> launchTargetsForFolder(
  Iterable<String> targets, {
  required String? folder,
  required bool isFirstFolder,
  String? selectedTarget,
  Iterable<String> knownFolders = const [],
}) {
  final inFolder = pathsInFolder(targets, folder);
  if (folder == null || !isFirstFolder || selectedTarget == null) {
    return inFolder;
  }
  final isListed =
      inFolder.any((target) => path.equals(target, selectedTarget));
  final isElsewhere = [folder, ...knownFolders]
      .any((known) => isInFolder(known, selectedTarget));
  if (isListed || isElsewhere) return inFolder;
  return [...inFolder, selectedTarget];
}
