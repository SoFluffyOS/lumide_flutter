import 'package:lumide_api/lumide_api.dart';

class SdkManager {
  final LumideContext context;

  SdkManager(this.context);

  /// Determines the command to use for Flutter based on the project root.
  /// Returns ['flutter'] or ['fvm', 'flutter'] or checks for others.
  Future<List<String>> getFlutterCommand(String? projectRoot) async {
    if (projectRoot != null) {
      // Check for FVM
      // FVM usually creates .fvm/fvm_config.json
      if (await context.fs.exists('$projectRoot/.fvm/fvm_config.json')) {
        return ['fvm', 'flutter'];
      }
    }

    return ['flutter'];
  }

  Future<String> getSdkVersion(List<String> command,
      {String? workingDir}) async {
    try {
      final result = await context.shell
          .run(command.first, [...command.sublist(1), '--version']);
      if (result.exitCode == 0) {
        // Output format: Flutter 3.19.0 • channel stable • ...
        final output = result.stdout.toString().split('\n').first;
        final version = output.split(' ')[1];
        return version;
      }
    } catch (e) {
      // ignore
    }
    return 'Unknown';
  }
}
