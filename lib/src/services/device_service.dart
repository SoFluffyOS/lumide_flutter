import 'dart:async';
import 'dart:io' as io;

import 'package:lumide_api/lumide_api.dart';
import 'package:lumide_flutter/src/constants.dart';
import 'package:lumide_flutter/src/services/daemon_service.dart';
import 'package:lumide_flutter/src/services/status_bar_service.dart';

class DeviceService {
  final LumideContext context;
  final StatusBarService statusBar;
  final DaemonService daemonService;

  List<Map<String, dynamic>> _devices = [];
  String? _selectedDeviceId;
  bool _isLoading = false;
  bool _isInitialized = false;

  StreamSubscription? _deviceAddedSub;
  StreamSubscription? _deviceRemovedSub;

  DeviceService(this.context, this.statusBar, this.daemonService);

  bool get _isMacOS => io.Platform.isMacOS;

  Future<void> init() async {
    _deviceAddedSub = daemonService.onDeviceAdded.listen((device) {
      if (!_devices.any((d) => d['id'] == device['id'])) {
        _devices.add(device);
        _selectedDeviceId ??= device['id'];
        _updateToolbar();
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
      _updateToolbar();
      if (_isInitialized) {
        context.window.showMessage('Device disconnected: ${device['name']}');
      }
    });

    await daemonService.enableDevicePolling();
  }

  Future<void> refreshDevices() async {
    _isLoading = true;
    await _updateToolbar();

    try {
      final devices =
          List<Map<String, dynamic>>.from(await daemonService.getDevices())
            ..sort((a, b) => _deviceSortRank(a).compareTo(_deviceSortRank(b)));
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
      await _updateToolbar();
    }
  }

  Future<void> selectDevice([Map<String, int>? position]) async {
    final devices = List<Map<String, dynamic>>.from(_devices)
      ..sort((a, b) => _deviceSortRank(a).compareTo(_deviceSortRank(b)));

    final hasIosSimulatorDevice = devices.any(_isIosSimulatorDevice);

    // Show cached devices immediately + Refresh option
    final items = devices.map((d) {
      final icon = _getDeviceIcon(d);

      return QuickPickItem(
        label: d['name'],
        description: d['id'],
        detail: d['isSupported'] == true ? 'Supported' : 'Unsupported',
        payload: d['id'],
        icon: icon,
      );
    }).toList();

    // Add divider/refresh option
    items.add(const QuickPickItem(label: '', isSeparator: true));

    if (_isMacOS && !hasIosSimulatorDevice) {
      items.add(const QuickPickItem(
        label: 'Start iOS Simulator',
        detail: 'Launch Apple Simulator app',
        payload: 'start-ios-simulator',
        icon: iconPlay,
      ));
    }

    items.add(const QuickPickItem(
      label: 'Refresh Devices...',
      detail: 'Scan for connected devices',
      payload: 'refresh',
      icon: iconRefresh,
    ));

    final selected = await context.window.showQuickPick(
      items,
      placeholder: 'Select a device',
      position: position,
    );

    if (selected != null) {
      final payload = selected.payload as String;
      if (payload == 'refresh') {
        await context.window.showMessage('Scanning for connected devices');
        await refreshDevices();
        await selectDevice(position); // Re-open picker
      } else if (payload == 'start-ios-simulator') {
        await _startIosSimulator();
      } else {
        _selectedDeviceId = payload;
        await _updateToolbar();
      }
    }
  }

  Future<void> _startIosSimulator() async {
    if (!_isMacOS) {
      return;
    }

    await context.window.showMessage('Starting iOS Simulator...');

    try {
      final result = await context.shell.run(
        'sh',
        ['-lc', 'open -a Simulator'],
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
      await _updateToolbar();
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
        await _updateToolbar();
        return true;
      }

      final detected = _findFirstIosSimulatorDevice(_devices);
      if (_trySelectDevice(detected)) {
        await _updateToolbar();
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
    final category = device['category']?.toString().toLowerCase() ?? '';
    final platformType = device['platformType']?.toString().toLowerCase() ?? '';
    final platform = device['platform']?.toString().toLowerCase() ?? '';
    final targetPlatform =
        device['targetPlatform']?.toString().toLowerCase() ?? '';

    final iosLikePlatform =
        platform == 'ios' || targetPlatform.startsWith('ios');

    return (category == 'mobile' || platformType == 'mobile') &&
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

  Future<void> _updateToolbar() async {
    if (_isLoading) {
      await context.toolbar.registerItem(
        id: cmdFlutterDevice,
        icon: iconSmartphone,
        label: 'Scanning...',
        tooltip: 'Scanning for devices...',
        alignment: ToolbarItemAlignment.right,
        priority: 200,
      );
      return;
    }

    String icon = iconSmartphone;
    String? label;
    String tooltip = 'Select Device';

    if (_selectedDeviceId != null) {
      final device = _devices.firstWhere((d) => d['id'] == _selectedDeviceId,
          orElse: () => {});
      if (device.isNotEmpty) {
        label = device['name'];
        tooltip = 'Device: ${device['name']}';
        icon = _getDeviceIcon(device);
      }
    } else {
      tooltip = 'No Devices Found';
    }

    await context.toolbar.registerItem(
      id: cmdFlutterDevice,
      icon: icon,
      label: label,
      tooltip: tooltip,
      alignment: ToolbarItemAlignment.right,
      priority: 200,
    );
  }

  String _getDeviceIcon(Map<String, dynamic> device) {
    // Flutter daemon device fields can vary.
    // Usually it has 'category', 'platformType', or 'platform'.
    final category = device['category']?.toString().toLowerCase() ?? '';
    final platformType = device['platformType']?.toString().toLowerCase() ?? '';
    final platform = device['platform']?.toString().toLowerCase() ?? '';
    final targetPlatform =
        device['targetPlatform']?.toString().toLowerCase() ?? '';

    // Web
    if (category == 'web' ||
        platformType == 'web' ||
        platform == 'web' ||
        targetPlatform.startsWith('web')) {
      return iconGlobe;
    }

    // Desktop
    if (category == 'desktop' ||
        platformType == 'desktop' ||
        ['darwin', 'macos', 'linux', 'windows'].contains(platform) ||
        ['darwin', 'macos', 'linux', 'windows']
            .any((p) => targetPlatform.startsWith(p))) {
      return iconMonitor;
    }

    // Default to smartphone for mobile (android, ios) or fallback
    return iconSmartphone;
  }

  String? get selectedDeviceId => _selectedDeviceId;

  Future<void> dispose() async {
    await _deviceAddedSub?.cancel();
    await _deviceRemovedSub?.cancel();
    await context.toolbar.unregisterItem(cmdFlutterDevice);
  }
}
