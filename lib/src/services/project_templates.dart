import 'package:lumide_api/lumide_api.dart';

/// The project templates `plugin.yaml` declares, by id.
enum FlutterProjectTemplate {
  app('flutter.app', ['--template', 'app']),
  empty('flutter.empty', ['--empty']),
  package('flutter.package', ['--template', 'package']),
  packageFfi('flutter.package_ffi', ['--template', 'package_ffi']),
  plugin('flutter.plugin', ['--template', 'plugin']),
  module('flutter.module', ['--template', 'module']);

  const FlutterProjectTemplate(this.id, this.templateArgs);

  /// The template's id in `plugin.yaml`.
  final String id;

  /// What `flutter create` is told about the kind of project.
  final List<String> templateArgs;

  static FlutterProjectTemplate? byId(String id) {
    for (final template in values) {
      if (template.id == id) {
        return template;
      }
    }

    return null;
  }

  /// The arguments of `flutter create` for [request], run in its parent
  /// folder. Only the fields this template declares are read.
  List<String> createArgs(LumideProjectCreateRequest request) {
    final platforms = request.choices('platforms');
    final org = request.text('org').trim();
    final androidLanguage = request.text('androidLanguage').trim();
    final description = request.text('description').trim();
    final getsPackages = switch (request.values['pub']) {
      final bool flag => flag,
      _ => true,
    };

    return [
      'create',
      ...templateArgs,
      if (platforms.isNotEmpty) ...['--platforms', platforms.join(',')],
      if (org.isNotEmpty) ...['--org', org],
      if (androidLanguage.isNotEmpty) ...[
        '--android-language',
        androidLanguage,
      ],
      if (description.isNotEmpty) ...['--description', description],
      if (!getsPackages) '--no-pub',
      if (request.flag('offline')) '--offline',
      '--project-name',
      request.packageName,
      request.name,
    ];
  }

  /// The file to open once the project is created, relative to it, for
  /// the package [name].
  String entryFile(String name) => switch (this) {
        app || empty || module => 'lib/main.dart',
        package || packageFfi || plugin => 'lib/$name.dart',
      };
}
