/// Individual DevTools screens that can be opened in their own Lumide pane.
enum DevToolsPage {
  inspector('inspector', 'Widget Inspector', 'scan-eye'),
  performance('performance', 'Performance', 'gauge'),
  cpuProfiler('cpu-profiler', 'CPU Profiler', 'cpu'),
  memory('memory', 'Memory', 'memory-stick'),
  network('network', 'Network', 'network'),
  logging('logging', 'Logging', 'logs');

  const DevToolsPage(this.id, this.title, this.icon);

  final String id;
  final String title;
  final String icon;

  String get command => 'flutter.devtools.$id';

  String url(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final fragment = Uri.parse(base.fragment);
    final parameters = {...base.queryParameters, ...fragment.queryParameters};
    parameters['embedMode'] = 'one';
    return base
        .replace(
          query: '',
          fragment: Uri(path: '/$id', queryParameters: parameters).toString(),
        )
        .toString();
  }
}
