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
      final devices = await daemonService.getDevices();
      _devices = List<Map<String, dynamic>>.from(devices);

      if (_devices.isNotEmpty) {
        if (_selectedDeviceId == null ||
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
    // Show cached devices immediately + Refresh option
    final items = _devices.map((d) {
      String icon = iconSmartphone;
      final platform = d['targetPlatform']?.toString().toLowerCase() ?? '';
      if (platform.startsWith('web')) {
        icon = iconGlobe;
      } else if (platform == 'darwin' ||
          platform.startsWith('windows') ||
          platform.startsWith('linux')) {
        icon = iconMonitor;
      }

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
      } else {
        _selectedDeviceId = payload;
        await _updateToolbar();
      }
    }
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

        final platform =
            device['targetPlatform']?.toString().toLowerCase() ?? '';

        if (platform.startsWith('web')) {
          icon = iconGlobe;
        } else if (platform == 'darwin' ||
            platform.startsWith('windows') ||
            platform.startsWith('linux')) {
          icon = iconMonitor;
        } else if (platform.startsWith('android') || platform == 'ios') {
          icon = iconSmartphone;
        }
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

  String? get selectedDeviceId => _selectedDeviceId;

  Future<void> dispose() async {
    await _deviceAddedSub?.cancel();
    await _deviceRemovedSub?.cancel();
    await context.toolbar.unregisterItem(cmdFlutterDevice);
  }
}
