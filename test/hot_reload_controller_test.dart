import 'dart:async';

import 'package:lumide_flutter/src/services/hot_reload_controller.dart';
import 'package:lumide_flutter/src/services/machine_requests.dart';
import 'package:test/test.dart';

void main() {
  group('MachineRequests', () {
    test('completes the request matching the response id', () async {
      final requests = MachineRequests();
      final (firstId, first) = requests.create();
      final (secondId, second) = requests.create();

      expect(
        requests.handle({
          'id': secondId,
          'result': {'code': 1, 'message': 'Reload rejected'},
        }),
        isTrue,
      );
      expect(
        requests.handle({
          'id': firstId,
          'result': {'code': 0, 'message': 'Reloaded 3 libraries'},
        }),
        isTrue,
      );

      final firstResult = await first;
      final secondResult = await second;
      expect(firstResult.isSuccess, isTrue);
      expect(firstResult.message, 'Reloaded 3 libraries');
      expect(secondResult.isSuccess, isFalse);
      expect(secondResult.message, 'Reload rejected');
    });

    test('reports transport errors as failures', () async {
      final requests = MachineRequests();
      final (id, response) = requests.create();

      requests.handle({'id': id, 'error': 'hot restart already in progress'});

      final result = await response;
      expect(result.isSuccess, isFalse);
      expect(result.cancelled, isFalse);
      expect(result.message, 'hot restart already in progress');
    });

    test('ignores events and unknown ids', () {
      final requests = MachineRequests();
      requests.create();

      expect(requests.handle({'event': 'app.log', 'id': 1}), isFalse);
      expect(requests.handle({'id': 42, 'result': null}), isFalse);
    });

    test('cancelAll resolves pending requests as cancelled', () async {
      final requests = MachineRequests();
      final (_, response) = requests.create();

      requests.cancelAll();

      expect((await response).cancelled, isTrue);
    });
  });

  group('HotReloadController', () {
    test('runs requests one at a time', () async {
      final sent = <bool>[];
      final gates = <Completer<MachineResult>>[];
      final controller = HotReloadController(
        send: ({required fullRestart}) {
          sent.add(fullRestart);
          final gate = Completer<MachineResult>();
          gates.add(gate);
          return gate.future;
        },
      );

      final reload = controller.reload();
      final restart = controller.restart();
      await pumpEventQueue();
      expect(sent, [false]);

      gates[0].complete(_ok);
      await reload;
      await pumpEventQueue();
      expect(sent, [false, true]);

      gates[1].complete(_ok);
      await restart;
    });

    test('joins reloads that are still waiting to start', () async {
      var sends = 0;
      final firstGate = Completer<MachineResult>();
      final controller = HotReloadController(
        send: ({required fullRestart}) {
          sends++;
          return switch (sends) {
            1 => firstGate.future,
            _ => Future.value(_ok),
          };
        },
      );

      final inFlight = controller.reload();
      await pumpEventQueue();
      final waitingA = controller.reload();
      final waitingB = controller.reload();
      expect(identical(waitingA, waitingB), isTrue);

      firstGate.complete(_ok);
      await Future.wait([inFlight, waitingA, waitingB]);
      expect(sends, 2);
    });

    test('debounces scheduled reloads', () async {
      var sends = 0;
      final controller = HotReloadController(
        debounce: const Duration(milliseconds: 20),
        send: ({required fullRestart}) async {
          sends++;
          return _ok;
        },
      );

      for (var i = 0; i < 5; i++) {
        controller.scheduleReload();
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(sends, 1);
    });

    test('reports each sent request once', () async {
      final reported = <String>[];
      final controller = HotReloadController(
        send: ({required fullRestart}) async =>
            const MachineResult(code: 1, message: 'Compile error'),
        onResult: (result, {required fullRestart}) {
          reported.add('$fullRestart:${result.message}');
        },
      );

      final first = controller.reload();
      final joined = controller.reload();
      await Future.wait([first, joined]);

      expect(reported, ['false:Compile error']);
    });

    test('keeps going when a send or report throws', () async {
      var sends = 0;
      final controller = HotReloadController(
        send: ({required fullRestart}) async {
          sends++;
          if (sends == 1) throw StateError('stdin closed');
          return _ok;
        },
        onResult: (result, {required fullRestart}) {
          throw StateError('report failed');
        },
      );

      final failed = await controller.reload();
      final next = await controller.restart();

      expect(failed.isSuccess, isFalse);
      expect(next.isSuccess, isTrue);
    });
  });
}

const _ok = MachineResult(code: 0, message: '');
