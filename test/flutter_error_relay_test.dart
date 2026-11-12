import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

void main() {
  test('writes Flutter.Error events as Flutter printed them', () async {
    final service = _Vm();
    final written = <String>[];
    final relay = FlutterErrorRelay(service, written.add);
    await relay.listen();

    service.post(_error({
      'renderedErrorText': '══╡ EXCEPTION CAUGHT BY RENDERING LIBRARY ╞══\n'
          'A RenderFlex overflowed by 42 pixels on the right.\n',
    }));
    service.post(Event(kind: EventKind.kExtension, extensionKind: 'Other'));
    await pumpEventQueue();

    expect(service.streams, [EventStreams.kExtension]);
    expect(written, [
      '══╡ EXCEPTION CAUGHT BY RENDERING LIBRARY ╞══\n'
          'A RenderFlex overflowed by 42 pixels on the right.',
    ]);

    await relay.dispose();
    expect(service.disposed, isTrue);
    service.post(_error({'renderedErrorText': 'After'}));
    await pumpEventQueue();
    expect(written, hasLength(1));
  });

  test('renders the description and first properties without text', () {
    final text = FlutterErrorRelay.render({
      'description': 'Exception caught by widgets library',
      'properties': [
        {'description': 'Null check operator used on a null value'},
        {'name': 'The relevant error-causing widget was', 'description': 'Foo'},
        {'name': 'hidden', 'showName': false, 'description': 'Bar'},
        {'name': 'empty'},
        'not a property',
        for (var index = 0; index < 20; index++) {'description': 'Line $index'},
      ],
    });

    expect(
      text.split('\n'),
      [
        'Exception caught by widgets library',
        'Null check operator used on a null value',
        'The relevant error-causing widget was: Foo',
        'Bar',
        'Line 0',
        'Line 1',
        'Line 2',
        'Line 3',
        'Line 4',
      ],
    );
  });

  test('ignores errors with nothing to show', () async {
    final service = _Vm();
    final written = <String>[];
    final relay = FlutterErrorRelay(service, written.add);
    await relay.listen();

    service.post(_error({'renderedErrorText': '  '}));
    await pumpEventQueue();

    expect(written, isEmpty);
    await relay.dispose();
  });

  test("a run's relay stops with the run", () async {
    final service = _Vm();
    final run = FlutterRun(
      kind: LumideLaunchKind.run,
      configurationId: 'main',
      process: _Process(),
    )..errorRelay = FlutterErrorRelay(service, (_) {});

    await run.dispose();

    expect(run.errorRelay, isNull);
    expect(service.disposed, isTrue);
  });
}

Event _error(Map<String, dynamic> data) {
  return Event(
    kind: EventKind.kExtension,
    extensionKind: 'Flutter.Error',
    extensionData: ExtensionData.parse(data),
  );
}

class _Vm implements VmService {
  final _events = StreamController<Event>.broadcast();
  final streams = <String>[];
  bool disposed = false;

  void post(Event event) => _events.add(event);

  @override
  Stream<Event> get onExtensionEvent => _events.stream;

  @override
  Future<Success> streamListen(String streamId) async {
    streams.add(streamId);
    return Success();
  }

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Process implements SdkProcess {
  @override
  Stream<String> get stdout => const Stream.empty();

  @override
  Stream<String> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  void write(String text) {}

  @override
  Future<void> kill({bool force = false}) async {}
}
