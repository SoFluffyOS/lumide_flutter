import 'package:lumide_flutter/src/services/import_assist.dart';
import 'package:lumide_flutter/src/services/project_service.dart';
import 'package:test/test.dart';

void main() {
  group('pubspecReferencesFlutter', () {
    test('detects sdk flutter', () {
      const content = '''
name: demo
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
''';
      expect(pubspecReferencesFlutter(content), isTrue);
    });

    test('rejects pure dart package', () {
      const content = '''
name: demo
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  path: ^1.9.0
''';
      expect(pubspecReferencesFlutter(content), isFalse);
    });
  });

  group('detectImportUris', () {
    test('detects material from Scaffold', () {
      const source = '''
class Home extends StatelessWidget {
  Widget build(BuildContext context) => Scaffold(body: Text('hi'));
}
''';
      final uris = detectImportUris(source);
      expect(uris, contains(importFlutterMaterial));
      expect(uris, isNot(contains(importFlutterWidgets)));
    });

    test('detects widgets alone for StatelessWidget without material', () {
      const source = '''
class Home extends StatelessWidget {
  Widget build(BuildContext context) => const Placeholder();
}
''';
      final uris = detectImportUris(source);
      expect(uris, contains(importFlutterWidgets));
      expect(uris, isNot(contains(importFlutterMaterial)));
    });

    test('detects cupertino from CupertinoApp', () {
      const source = '''
Widget build() => CupertinoApp(home: CupertinoPageScaffold(child: Text('x')));
''';
      final uris = detectImportUris(source);
      expect(uris, contains(importFlutterCupertino));
      expect(uris, isNot(contains(importFlutterWidgets)));
    });

    test('detects services without material', () {
      const source = '''
Future<void> copy(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}
''';
      expect(detectImportUris(source), contains(importFlutterServices));
    });

    test('does not add painting when material already covers EdgeInsets', () {
      const source = '''
Widget build() => Scaffold(
  body: Padding(padding: EdgeInsets.all(8), child: Text('x')),
);
''';
      final uris = detectImportUris(source);
      expect(uris, contains(importFlutterMaterial));
      expect(uris, isNot(contains(importFlutterPainting)));
    });

    test('detects flutter_test only for test files', () {
      const source = '''
void main() {
  testWidgets('x', (tester) async {
    await tester.pumpWidget(const Placeholder());
  });
}
''';
      expect(detectImportUris(source), isNot(contains(importFlutterTest)));
      expect(
        detectImportUris(source, path: 'test/home_test.dart'),
        contains(importFlutterTest),
      );
    });
  });

  group('neededImports', () {
    test('skips already imported uris', () {
      const source = '''
import 'package:flutter/material.dart';

class Home extends StatelessWidget {
  Widget build(BuildContext context) => Scaffold();
}
''';
      expect(neededImports(source), isEmpty);
    });

    test('returns only missing uris', () {
      const source = '''
class Home extends StatelessWidget {
  Widget build(BuildContext context) => const Placeholder();
}
''';
      expect(neededImports(source), {importFlutterWidgets});
    });
  });

  group('insertImports', () {
    test('inserts after existing imports', () {
      const source = '''
import 'dart:async';

class A {}
''';
      final result = insertImports(source, {importFlutterMaterial});
      expect(
        result,
        '''
import 'dart:async';
import 'package:flutter/material.dart';

class A {}
''',
      );
    });

    test('sorts multiple imports alphabetically by URI', () {
      const source = 'class A {}\n';
      final result = insertImports(source, {
        importFlutterWidgets,
        importFlutterCupertino,
        importFlutterMaterial,
      });
      final cupertino = result.indexOf("import '$importFlutterCupertino';");
      final material = result.indexOf("import '$importFlutterMaterial';");
      final widgets = result.indexOf("import '$importFlutterWidgets';");
      expect(cupertino, lessThan(material));
      expect(material, lessThan(widgets));
    });
  });

  group('unusedImports / removeImports', () {
    test('detects unused managed widgets import', () {
      const source = '''
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';

class Home extends StatelessWidget {
  Widget build(BuildContext context) => Scaffold();
}
''';
      expect(unusedImports(source), {importFlutterWidgets});
    });

    test('keeps material when Scaffold is used', () {
      const source = '''
import 'package:flutter/material.dart';

class Home extends StatelessWidget {
  Widget build(BuildContext context) => Scaffold();
}
''';
      expect(unusedImports(source), isEmpty);
    });

    test('does not treat unrelated packages as unused managed', () {
      const source = '''
import 'package:http/http.dart';
import 'package:flutter/painting.dart';

class A {}
''';
      expect(unusedImports(source), {importFlutterPainting});
      final removed = removeImports(source, unusedImports(source));
      expect(removed, contains("import 'package:http/http.dart';"));
      expect(removed, isNot(contains("import 'package:flutter/painting.dart';")));
    });

    test('does not remove export directives', () {
      const source = '''
export 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

class A {}
''';
      final removed =
          removeImports(source, {importFlutterMaterial, importFlutterWidgets});
      expect(removed, contains("export 'package:flutter/material.dart';"));
      expect(
        removed,
        isNot(contains("import 'package:flutter/widgets.dart';")),
      );
    });
  });

  group('syncImports', () {
    test('adds missing and removes unused in one pass', () {
      const source = '''
import 'package:flutter/painting.dart';

class Home extends StatelessWidget {
  Widget build(BuildContext context) => Scaffold();
}
''';
      final result = syncImports(source);
      expect(result.removed, {importFlutterPainting});
      expect(result.added, {importFlutterMaterial});
      expect(
        result.source,
        contains("import 'package:flutter/material.dart';"),
      );
      expect(
        result.source,
        isNot(contains("import 'package:flutter/painting.dart';")),
      );
    });

    test('removeUnused false only adds', () {
      const source = '''
import 'package:flutter/painting.dart';

class Home extends StatelessWidget {
  Widget build(BuildContext context) => const Placeholder();
}
''';
      final result = syncImports(source, removeUnused: false);
      expect(result.removed, isEmpty);
      expect(result.added, {importFlutterWidgets});
      expect(
        result.source,
        contains("import 'package:flutter/painting.dart';"),
      );
    });
  });
}
