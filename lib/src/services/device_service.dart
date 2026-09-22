import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/services.dart';

class DeviceService {
  final LumideContext context;
  final StatusBarService statusBar;
  final DaemonService daemonService;

  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>>? _emulators;
  Future<List<Map<String, dynamic>>>? _emulatorDiscovery;
  Object? _emulatorDiscoveryError;
  String? _selectedDeviceId;
  bool _launchingEmulator = false;
  bool _disposed = false;
  int _selectionVersion = 0;
  final _disposeSignal = Completer<void>();
  Future<void>? _refreshInFlight;
  Future<void>? _pickerInFlight;
  final Duration emulatorBootTimeout;
  final Duration emulatorPollInterval;
  final Duration discoveryTimeout;
  bool _isLoading = false;
  bool _isInitialized = false;
  Future<void> Function()? onDidChange;

  StreamSubscription? _deviceAddedSub;
  StreamSubscription? _deviceRemovedSub;

  DeviceService(
    this.context,
    this.statusBar,
    this.daemonService, {
    this.emulatorBootTimeout = const Duration(seconds: 90),
    this.emulatorPollInterval = const Duration(seconds: 2),
    this.discoveryTimeout = const Duration(seconds: 5),
  });

  bool get _isMacOS => io.Platform.isMacOS;

  Future<void> init() async {
    _deviceAddedSub = daemonService.onDeviceAdded.listen((device) {
      if (!_devices.any((d) => d['id'] == device['id'])) {
        _devices.add(device);
        _selectedDeviceId ??= device['id'];
        _notifyChanged();
        if (_isInitialized) {
          context.window.showMessage('Device connected: ${device['name']}');
        }
      }
    });

    _deviceRemovedSub = daemonService.onDeviceRemoved.listen((device) {
      _devices.removeWhere((d) => d['id'] == device['id']);
      if (_selectedDeviceId == device['id']) {
        _selectedDeviceId =
            _devices.isNotEmpty ? _devices.first['id'] as String? : null;
      }
      _notifyChanged();
      if (_isInitialized) {
        context.window.showMessage('Device disconnected: ${device['name']}');
      }
    });
  }

  Future<void> refreshDevices({bool showLoading = true}) {
    if (_disposed) return Future.value();
    final pending = _refreshInFlight;
    if (pending != null) return pending;
    final refresh = _refreshDevices(showLoading: showLoading);
    _refreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    });
  }

  Future<void> _refreshDevices({required bool showLoading}) async {
    final previousDevices = jsonEncode(_devices);
    final previousSelection = _selectedDeviceId;
    if (showLoading) {
      _isLoading = true;
      await _notifyChanged();
    }
    try {
      await daemonService.enableDevicePolling();
      final devices =
          List<Map<String, dynamic>>.from(await daemonService.getDevices())
            ..sort((a, b) => _deviceSortRank(a).compareTo(_deviceSortRank(b)));
      if (_disposed) return;
      _devices = List<Map<String, dynamic>>.from(devices);

      if (_devices.isNotEmpty) {
        if (!_isInitialized) {
          // During startup, prefer the best-ranked device from the refreshed list.
          _selectedDeviceId = _devices.first['id'] as String?;
        } else if (_selectedDeviceId == null ||
            !_devices.any((d) => d['id'] == _selectedDeviceId)) {
          _selectedDeviceId = _devices.first['id'];
        }
      } else {
        _selectedDeviceId = null;
      }
    } catch (e) {
      io.stderr.writeln('Failed to list devices: $e');
    } finally {
      _isLoading = false;
      _isInitialized = true;
      if (showLoading ||
          previousDevices != jsonEncode(_devices) ||
          previousSelection != _selectedDeviceId) {
        await _notifyChanged();
      }
    }
  }

  Future<void> selectDevice([Map<String, int>? position]) {
    if (_disposed) return Future.value();
    final pending = _pickerInFlight;
    if (pending != null) return pending;
    final picker = _selectDevice(position);
    _pickerInFlight = picker;
    return picker.whenComplete(() {
      if (identical(_pickerInFlight, picker)) _pickerInFlight = null;
    });
  }

  Future<void> _selectDevice(Map<String, int>? position) async {
    if (!_isInitialized) await refreshDevices();
    if (_disposed) return;
    unawaited(_discoverEmulators());
    final devices = List<Map<String, dynamic>>.from(_devices)
      ..sort((a, b) => _deviceSortRank(a).compareTo(_deviceSortRank(b)));

    final hasIosSimulatorDevice = devices.any(_isIosSimulatorDevice);

    // Show cached devices immediately.
    final items = devices.map((d) {
      final icon = _getDeviceIcon(d);
      final tooltip = [
        d['id'],
        d['platformType'],
        d['sdk'],
      ].join(' • ');

      return QuickPickItem(
        label: d['name'],
        description: d['id'],
        detail: d['id'],
        tooltip: tooltip,
        payload: d['id'],
        icon: icon,
      );
    }).toList();

    if (items.isNotEmpty) {
      items.add(const QuickPickItem(label: '', isSeparator: true));
    }

    final emulators = _emulators ?? const <Map<String, dynamic>>[];
    for (final emulator in emulators) {
      final id = emulator['id'];
      if (id is! String ||
          id == 'apple_ios_simulator' ||
          devices.any((device) => device['emulatorId'] == id)) {
        continue;
      }
      items.add(QuickPickItem(
        label: emulator['name']?.toString() ?? id,
        description: 'Android Virtual Device',
        detail: 'Launch $id',
        payload: 'emulator:$id',
        icon: iconSmartphone,
      ));
    }

    items.add(const QuickPickItem(
      label: 'Android Virtual Devices...',
      detail: 'Show stopped Android emulators',
      payload: 'show-emulators',
      icon: iconSmartphone,
    ));

    if (_isMacOS && !hasIosSimulatorDevice) {
      items.add(const QuickPickItem(
        label: 'Start iOS Simulator',
        detail: 'Launch Simulator',
        tooltip:
            'Launch Apple Simulator and select the first detected iOS simulator device.',
        payload: 'start-ios-simulator',
        icon: iconPlay,
      ));
    }

    items.add(const QuickPickItem(
      label: 'Refresh Devices...',
      detail: 'Scan devices',
      tooltip:
          'Scan for connected Flutter devices, simulators, emulators, and browsers.',
      payload: 'refresh',
      icon: iconRefresh,
    ));

    final selected = await context.window.showQuickPick(
      items,
      placeholder: 'Select a device',
      position: position,
    );

    if (_disposed) return;
    if (selected != null) {
      final payload = selected.payload as String;
      if (payload.startsWith('emulator:')) {
        await launchEmulator(payload.substring('emulator:'.length));
        return;
      }
      if (payload == 'show-emulators') {
        await _selectEmulator(position);
        return;
      }
      if (payload == 'refresh') {
        await context.window.showMessage('Scanning for connected devices');
        _emulators = null;
        _emulatorDiscoveryError = null;
        await refreshDevices();
        await _selectDevice(position); // Re-open the same picker operation
      } else if (payload == 'start-ios-simulator') {
        _selectionVersion++;
        await _startIosSimulator();
      } else {
        _selectionVersion++;
        _selectedDeviceId = payload;
        await _notifyChanged();
      }
    }
  }

  Future<void> _selectEmulator(Map<String, int>? position) async {
    final emulators = await _discoverEmulators();
    if (_disposed) return;
    if (_emulatorDiscoveryError != null) {
      await context.window.showMessage(
        'Could not list Android emulators. Check the Android SDK and try again.',
        type: MessageType.warning,
      );
      return;
    }
    final items = emulators
        .where((emulator) =>
            emulator['id'] is String && emulator['id'] != 'apple_ios_simulator')
        .where((emulator) => !_devices.any(
              (device) => device['emulatorId'] == emulator['id'],
            ))
        .map((emulator) {
      final id = emulator['id'] as String;
      return QuickPickItem(
        label: emulator['name']?.toString() ?? id,
        description: 'Android Virtual Device',
        detail: 'Launch $id',
        payload: 'emulator:$id',
        icon: iconSmartphone,
      );
    }).toList();
    if (items.isEmpty) {
      await context.window
          .showMessage('No stopped Android Virtual Devices found.');
      return;
    }
    final selected = await context.window.showQuickPick(
      items,
      placeholder: 'Select an Android Virtual Device',
      position: position,
    );
    if (_disposed) return;
    final payload = selected?.payload;
    if (payload is String && payload.startsWith('emulator:')) {
      await launchEmulator(payload.substring('emulator:'.length));
    }
  }

  Future<List<Map<String, dynamic>>> _discoverEmulators() {
    if (_disposed) return Future.value(const []);
    final cached = _emulators;
    if (cached != null) return Future.value(cached);
    final pending = _emulatorDiscovery;
    if (pending != null) return pending;
    final discovery = _loadEmulators();
    _emulatorDiscovery = discovery;
    return discovery.whenComplete(() {
      if (identical(_emulatorDiscovery, discovery)) _emulatorDiscovery = null;
    });
  }

  Future<List<Map<String, dynamic>>> _loadEmulators() async {
    try {
      final result =
          await daemonService.getEmulators().timeout(discoveryTimeout);
      if (_disposed) return const [];
      _emulatorDiscoveryError = null;
      _emulators = result;
      return result;
    } catch (error) {
      if (_disposed) return const [];
      _emulatorDiscoveryError = error;
      daemonService.logService.error('Failed to list Android emulators', error);
      _emulators = const [];
      return const [];
    }
  }

  Future<void> launchEmulator(String emulatorId) async {
    if (_launchingEmulator || _disposed) return;
    _launchingEmulator = true;
    final selectionVersion = ++_selectionVersion;
    final watch = Stopwatch()..start();
    Future<T> withinDeadline<T>(Future<T> operation) => operation.timeout(
          emulatorBootTimeout - watch.elapsed,
        );
    try {
      await context.window
          .showMessage('Starting Android emulator $emulatorId...');
      await Future.any<void>([
        withinDeadline(daemonService.launchEmulator(emulatorId)),
        _disposeSignal.future,
      ]);
      while (!_disposed && selectionVersion == _selectionVersion) {
        await Future.any<void>([
          withinDeadline(refreshDevices(showLoading: false)),
          _disposeSignal.future,
        ]);
        if (_disposed || selectionVersion != _selectionVersion) return;
        final device = _devices
            .where(
              (device) => device['emulatorId'] == emulatorId,
            )
            .firstOrNull;
        if (_trySelectDevice(device)) {
          await _notifyChanged();
          return;
        }
        await Future.any<void>([
          withinDeadline(Future<void>.delayed(emulatorPollInterval)),
          _disposeSignal.future,
        ]);
      }
    } on TimeoutException {
      if (_disposed || selectionVersion != _selectionVersion) return;
      await context.window.showMessage(
        'Android emulator did not become ready in time. It may still be booting; use Refresh Devices to check.',
        type: MessageType.warning,
      );
    } catch (error) {
      if (_disposed || selectionVersion != _selectionVersion) return;
      await context.window.showMessage(
        'Failed to launch Android emulator: $error',
        type: MessageType.error,
      );
    } finally {
      watch.stop();
      _launchingEmulator = false;
    }
  }

  Future<void> selectDeviceById(String deviceId) async {
    final match = _devices.where((d) => d['id'] == deviceId).firstOrNull;
    if (match != null && !_disposed) {
      _selectionVersion++;
      _selectedDeviceId = deviceId;
      await _notifyChanged();
    }
  }

  Future<void> _startIosSimulator() async {
    if (!_isMacOS) {
      return;
    }

    await context.window.showMessage('Starting iOS Simulator...');

    try {
      final result = await context.shell.run(
        'open',
        ['-a', 'Simulator'],
      );
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        await context.window.showMessage(
          stderr.isNotEmpty
              ? 'Failed to start iOS Simulator: $stderr'
              : 'Failed to start iOS Simulator.',
          type: MessageType.error,
        );
        return;
      }
      final selected = await _waitAndSelectIosSimulator();
      if (!selected) {
        await context.window.showMessage(
          'Simulator started, but no iOS simulator device was detected yet. Try Refresh Devices.',
          type: MessageType.warning,
        );
      }
    } catch (e) {
      await context.window.showMessage(
        'Failed to start iOS Simulator: $e',
        type: MessageType.error,
      );
    }
  }

  Future<bool> _waitAndSelectIosSimulator() async {
    await refreshDevices();

    final existing = _findFirstIosSimulatorDevice(_devices);
    if (_trySelectDevice(existing)) {
      await _notifyChanged();
      return true;
    }

    final completer = Completer<Map<String, dynamic>?>();
    late final StreamSubscription<Map<String, dynamic>> addedSub;
    addedSub = daemonService.onDeviceAdded.listen((device) {
      if (!completer.isCompleted && _isIosSimulatorDevice(device)) {
        completer.complete(device);
      }
    });

    try {
      final addedDevice = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => null,
      );

      await refreshDevices();

      if (_trySelectDevice(addedDevice)) {
        await _notifyChanged();
        return true;
      }

      final detected = _findFirstIosSimulatorDevice(_devices);
      if (_trySelectDevice(detected)) {
        await _notifyChanged();
        return true;
      }
    } finally {
      await addedSub.cancel();
    }

    return false;
  }

  Map<String, dynamic>? _findFirstIosSimulatorDevice(
      List<Map<String, dynamic>> devices) {
    for (final device in devices) {
      if (_isIosSimulatorDevice(device)) {
        return device;
      }
    }
    return null;
  }

  bool _trySelectDevice(Map<String, dynamic>? device) {
    if (device == null) return false;
    final id = device['id'];
    if (id is! String || id.isEmpty) return false;
    _selectedDeviceId = id;
    return true;
  }

  int _deviceSortRank(Map<String, dynamic> device) {
    if (_isMacOS && _isIosSimulatorDevice(device)) {
      return 0;
    }
    if (_isMacOS && _isMacOsDesktopDevice(device)) {
      return 1;
    }
    return 2;
  }

  bool _isIosSimulatorDevice(Map<String, dynamic> device) {
    final isEmulator = device['emulator'] == true;
    final category = device['category']?.toString().toLowerCase() ?? '';
    final platformType = device['platformType']?.toString().toLowerCase() ?? '';
    final platform = device['platform']?.toString().toLowerCase() ?? '';
    final targetPlatform =
        device['targetPlatform']?.toString().toLowerCase() ?? '';

    final iosLikePlatform =
        platform == 'ios' || targetPlatform.startsWith('ios');

    return isEmulator &&
        (category == 'mobile' || platformType == 'mobile') &&
        iosLikePlatform;
  }

  bool _isMacOsDesktopDevice(Map<String, dynamic> device) {
    final category = device['category']?.toString().toLowerCase() ?? '';
    final platformType = device['platformType']?.toString().toLowerCase() ?? '';
    final platform = device['platform']?.toString().toLowerCase() ?? '';
    final targetPlatform =
        device['targetPlatform']?.toString().toLowerCase() ?? '';

    return category == 'desktop' &&
        (platformType == 'desktop' ||
            platform == 'darwin' ||
            platform == 'macos' ||
            targetPlatform.startsWith('darwin') ||
            targetPlatform.startsWith('macos'));
  }

  Future<void> _notifyChanged() async {
    if (_disposed) return;
    final callback = onDidChange;
    if (callback != null) {
      await callback();
    }
  }

  String get displayIcon {
    if (_isLoading) {
      return iconSmartphone;
    }

    if (_selectedDeviceId != null) {
      final device = _devices.firstWhere((d) => d['id'] == _selectedDeviceId,
          orElse: () => {});
      if (device.isNotEmpty) {
        return _getDeviceIcon(device);
      }
    }

    return iconSmartphone;
  }

  String get displayLabel {
    if (_isLoading) {
      return 'Scanning...';
    }

    if (!_isInitialized) return 'Select Device';

    if (_selectedDeviceId != null) {
      final device = _devices.firstWhere((d) => d['id'] == _selectedDeviceId,
          orElse: () => {});
      if (device.isNotEmpty) {
        return device['name']?.toString() ?? _selectedDeviceId!;
      }
    }

    return 'Device';
  }

  String get displayTooltip {
    if (_isLoading) {
      return 'Scanning for devices...';
    }

    if (!_isInitialized) return 'Select to scan for Flutter devices';

    if (_selectedDeviceId != null) {
      final device = _devices.firstWhere((d) => d['id'] == _selectedDeviceId,
          orElse: () => {});
      if (device.isNotEmpty) {
        return 'Device: ${device['name']}';
      }
    }

    return 'No Devices Found';
  }

  String _getDeviceIcon(Map<String, dynamic> device) {
    // Flutter daemon device fields can vary.
    // Usually it has 'category', 'platformType', or 'platform'.
    final category = device['category']?.toString().toLowerCase() ?? '';
    final platformType = device['platformType']?.toString().toLowerCase() ?? '';
    final platform = device['platform']?.toString().toLowerCase() ?? '';
    final targetPlatform =
        device['targetPlatform']?.toString().toLowerCase() ?? '';

    if (category == 'web' ||
        platformType == 'web' ||
        platform == 'web' ||
        targetPlatform.startsWith('web')) {
      return iconGlobe;
    }

    if (category == 'desktop' ||
        platformType == 'desktop' ||
        ['darwin', 'macos', 'linux', 'windows'].contains(platform) ||
        ['darwin', 'macos', 'linux', 'windows']
            .any((p) => targetPlatform.startsWith(p))) {
      return iconMonitor;
    }

    return iconSmartphone;
  }

  String? get selectedDeviceId => _selectedDeviceId;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _selectionVersion++;
    _disposeSignal.complete();
    await _deviceAddedSub?.cancel();
    await _deviceRemovedSub?.cancel();
    await context.toolbar.unregisterItem(cmdFlutterDevice);
  }
}
