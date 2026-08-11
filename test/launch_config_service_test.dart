import 'package:lumide_flutter/src/services/launch_config_service.dart';
import 'package:test/test.dart';

void main() {
  test('decodes VS Code JSONC comments and trailing commas', () {
    final decoded = decodeVscodeLaunchJsonc(r'''
{
  // VS Code permits comments and trailing commas.
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Flutter",
      "type": "dart",
      "request": "launch",
      "program": "${workspaceFolder}/lib/main.dart",
      "args": [
        "--dart-define=URL=https://example.com",
      ],
    },
  ],
}
''') as Map<String, dynamic>;

    final configurations = decoded['configurations'] as List;
    expect(configurations, hasLength(1));
    expect(
      (configurations.single as Map<String, dynamic>)['program'],
      r'${workspaceFolder}/lib/main.dart',
    );
  });

  test('does not remove comma-like content from JSON strings', () {
    final decoded = decodeVscodeLaunchJsonc(
      r'{"configurations":[{"args":["value,}","https://host/path,//ok"],},],}',
    ) as Map<String, dynamic>;

    final configurations = decoded['configurations'] as List;
    final configuration = configurations.single as Map<String, dynamic>;
    expect(configuration['args'], ['value,}', 'https://host/path,//ok']);
  });
}
