import 'dart:async';

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/services/services.dart';
import 'package:test/test.dart';

void main() {
  test('picker lists stopped AVDs and selects the launched runtime device ID',
      () async {
    final context = _Context();
    final daemon = _Daemon(context);
    final devices = DeviceService(context, StatusBarService(context), daemon);
    context.window.choose = 'show-emulators';
    context.window.emulatorChoice = 'emulator:Pixel_9';
    await devices.selectDevice();
    expect(context.window.items.map((item) => item.payload),
        contains('emulator:Pixel_9'));
    expect(context.window.items.map((item) => item.payload),
        isNot(contains('emulator:Running_AVD')));
    expect(context.window.items.map((item) => item.payload),
        isNot(contains('emulator:apple_ios_simulator')));
    expect(daemon.launched, 'Pixel_9');
    expect(devices.selectedDeviceId, 'emulator-5556');
  });

  test('failed AVD discovery still allows selecting connected devices',
      () async {
    final context = _Context();
    final daemon = _Daemon(context)..failDiscovery = true;
    final devices = DeviceService(context, StatusBarService(context), daemon);
    context.window.choose = 'show-emulators';
    await devices.selectDevice();
    expect(devices.selectedDeviceId, 'emulator-5554');
    expect(context.window.messages, contains(contains('Could not list')));
  });

  test('later device choices win over emulator auto-selection', () async {
    final context = _Context();
    final daemon = _Daemon(context)..pendingLaunch = Completer<void>();
    final devices = DeviceService(context, StatusBarService(context), daemon);
    await devices.refreshDevices();
    final launch = devices.launchEmulator('Pixel_9');
    await Future<void>.delayed(Duration.zero);
    await devices.selectDeviceById('emulator-5554');
    daemon.pendingLaunch?.complete();
    await launch;
    expect(devices.selectedDeviceId, 'emulator-5554');
  });

  test('emulator deadline bounds a stalled launch and permits retry', () async {
    final context = _Context();
    final daemon = _Daemon(context)..pendingLaunch = Completer<void>();
    final devices = DeviceService(context, StatusBarService(context), daemon,
        emulatorBootTimeout: const Duration(milliseconds: 20));
    await devices.refreshDevices();
    await devices.launchEmulator('Pixel_9');
    expect(context.window.messages.last, contains('did not become ready'));
    expect(devices.selectedDeviceId, 'emulator-5554');
    daemon.pendingLaunch?.complete();
    daemon.pendingLaunch = null;
    await devices.launchEmulator('Pixel_9');
    expect(devices.selectedDeviceId, 'emulator-5556');
  });

  test('quiet polling skips unchanged notifications and coalesces refreshes',
      () async {
    final context = _Context();
    final daemon = _Daemon(context);
    final devices = DeviceService(context, StatusBarService(context), daemon);
    await devices.refreshDevices();
    var changes = 0;
    devices.onDidChange = () async {
      changes++;
    };
    final pending = Completer<void>();
    daemon.pendingRefresh = pending;
    final first = devices.refreshDevices(showLoading: false);
    final second = devices.refreshDevices(showLoading: false);
    await Future<void>.delayed(Duration.zero);
    expect(daemon.deviceRequests, 2); // Initial refresh plus one shared poll.
    pending.complete();
    await Future.wait([first, second]);
    expect(changes, 0);
  });

  test('discovery timeout still presents connected devices', () async {
    final context = _Context();
    final daemon = _Daemon(context)..pendingDiscovery = Completer<void>();
    final devices = DeviceService(context, StatusBarService(context), daemon,
        discoveryTimeout: const Duration(milliseconds: 10));
    context.window.choose = 'emulator-5554';
    await devices.selectDevice();
    expect(devices.selectedDeviceId, 'emulator-5554');
    expect(context.window.items.map((item) => item.payload),
        contains('show-emulators'));
    expect(
        context.window.messages, isNot(contains(contains('Could not list'))));
    daemon.pendingDiscovery?.complete();
  });

  test('connected devices appear without waiting for AVD discovery', () async {
    final context = _Context();
    final daemon = _Daemon(context)..pendingDiscovery = Completer<void>();
    final devices = DeviceService(context, StatusBarService(context), daemon);
    context.window.choose = 'emulator-5554';
    await devices.selectDevice();
    expect(devices.selectedDeviceId, 'emulator-5554');
    expect(daemon.emulatorRequests, 1);
    daemon.pendingDiscovery?.complete();
  });

  test('background AVD results appear on the next picker opening', () async {
    final context = _Context();
    final daemon = _Daemon(context)..pendingDiscovery = Completer<void>();
    final devices = DeviceService(context, StatusBarService(context), daemon);
    context.window.choose = 'emulator-5554';
    await devices.selectDevice();
    daemon.pendingDiscovery?.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    context.window.choose = 'emulator:Pixel_9';
    await devices.selectDevice();
    expect(context.window.items.map((item) => item.payload),
        contains('emulator:Pixel_9'));
    expect(daemon.emulatorRequests, 1);
    expect(devices.selectedDeviceId, 'emulator-5556');
  });

  test('dispose cancels launch waiting without later notifications', () async {
    final context = _Context();
    final daemon = _Daemon(context)..pendingLaunch = Completer<void>();
    final devices = DeviceService(context, StatusBarService(context), daemon);
    final launch = devices.launchEmulator('Pixel_9');
    await Future<void>.delayed(Duration.zero);
    await devices.dispose();
    final count = context.window.messages.length;
    await launch;
    daemon.pendingLaunch?.complete();
    await Future<void>.delayed(Duration.zero);
    expect(context.window.messages.length, count);
  });

  test('failed launches report an error and preserve the selected device',
      () async {
    final context = _Context();
    final daemon = _Daemon(context)..failLaunch = true;
    final devices = DeviceService(context, StatusBarService(context), daemon);
    await devices.refreshDevices();
    final selected = devices.selectedDeviceId;
    await devices.launchEmulator('Pixel_9');
    expect(devices.selectedDeviceId, selected);
    expect(context.window.messages, contains(contains('Failed to launch')));
  });
}

class _Daemon extends DaemonService {
  _Daemon(LumideContext context)
      : super(context, ProjectService(context), SdkManager(context),
            LogService((_) {}));
  bool failDiscovery = false;
  bool failLaunch = false;
  String? launched;
  Completer<void>? pendingLaunch;
  Completer<void>? pendingRefresh;
  Completer<void>? pendingDiscovery;
  int deviceRequests = 0;
  int emulatorRequests = 0;
  @override
  Future<void> enableDevicePolling() async {}
  @override
  Future<List<Map<String, dynamic>>> getDevices() async {
    deviceRequests++;
    await pendingRefresh?.future;
    return [
      {
        'id': 'emulator-5554',
        'name': 'Running AVD',
        'emulatorId': 'Running_AVD'
      },
      if (launched != null)
        {'id': 'emulator-5556', 'name': 'Pixel 9', 'emulatorId': launched},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getEmulators() async {
    emulatorRequests++;
    await pendingDiscovery?.future;
    if (failDiscovery) throw StateError('SDK unavailable');
    return [
      {'id': 'Pixel_9', 'name': 'Pixel 9'},
      {'id': 'Running_AVD', 'name': 'Running AVD'},
      {'id': 'apple_ios_simulator', 'name': 'iOS Simulator'},
    ];
  }

  @override
  Future<void> launchEmulator(String emulatorId) async {
    await pendingLaunch?.future;
    if (failLaunch) throw StateError('Launch failed');
    launched = emulatorId;
  }
}

class _Context implements LumideContext {
  @override
  final _Window window = _Window();
  @override
  final LumideToolbar toolbar = _Toolbar();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Window implements LumideWindow {
  List<QuickPickItem> items = [];
  final messages = <String>[];
  String? choose;
  String? emulatorChoice;
  @override
  Future<void> showMessage(String message,
      {MessageType type = MessageType.info, String? title}) async {
    messages.add(message);
  }

  @override
  Future<QuickPickItem?> showQuickPick(
    List<QuickPickItem> items, {
    String? placeholder,
    bool matchOnDescription = true,
    bool matchOnDetail = true,
    Map<String, int>? position,
  }) async {
    this.items = items;
    final choice = placeholder == 'Select an Android Virtual Device'
        ? emulatorChoice
        : choose;
    return items.where((item) => item.payload == choice).firstOrNull;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Toolbar implements LumideToolbar {
  @override
  Future<void> unregisterItem(String id) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
