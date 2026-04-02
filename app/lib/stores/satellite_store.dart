import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart';

class SatelliteState {
  final String serverUrl;
  final String satelliteName;
  final String satelliteId;
  final bool hasPermissions;

  const SatelliteState({
    this.serverUrl = '',
    this.satelliteName = 'Unnamed Satellite',
    this.satelliteId = '',
    this.hasPermissions = false,
  });

  bool get isConfigured => serverUrl.isNotEmpty;

  SatelliteState copyWith({
    String? serverUrl,
    String? satelliteName,
    String? satelliteId,
    bool? hasPermissions,
  }) {
    return SatelliteState(
      serverUrl: serverUrl ?? this.serverUrl,
      satelliteName: satelliteName ?? this.satelliteName,
      satelliteId: satelliteId ?? this.satelliteId,
      hasPermissions: hasPermissions ?? this.hasPermissions,
    );
  }
}

class SatelliteStore {
  static final SatelliteStore _instance = SatelliteStore._internal();
  factory SatelliteStore() => _instance;
  SatelliteStore._internal();

  late final Signal<SatelliteState> state = signal(const SatelliteState());

  final TextEditingController urlController = TextEditingController();
  final TextEditingController nameController = TextEditingController();

  Future<void> init() async {
    await loadConfiguration();
    await checkPermissions();
  }

  Future<void> loadConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url') ?? '';
    final name = prefs.getString('satellite_name') ?? 'Unnamed Satellite';
    var id = prefs.getString('satellite_id') ?? '';

    if (id.isEmpty) {
      id = _generateSatelliteId();
      await prefs.setString('satellite_id', id);
    }

    state.value = state.value.copyWith(
      serverUrl: url,
      satelliteName: name,
      satelliteId: id,
    );
    urlController.text = url;
    nameController.text = name;
  }

  Future<void> saveConfiguration(String url, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
    await prefs.setString('satellite_name', name);

    state.value = state.value.copyWith(
      serverUrl: url,
      satelliteName: name.isEmpty ? 'Unnamed Satellite' : name,
    );
  }

  Future<void> clearConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server_url');
    await prefs.remove('satellite_name');

    state.value = const SatelliteState();
    urlController.text = '';
    nameController.text = '';
  }

  Future<void> checkPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    final notifications = prefs.getBool('notifications_granted') ?? false;
    state.value = state.value.copyWith(hasPermissions: notifications);
  }

  Future<void> requestPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_granted', true);
    state.value = state.value.copyWith(hasPermissions: true);
  }

  String _generateSatelliteId() {
    final random = Random();
    final millis = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final suffix = random.nextInt(1 << 20).toRadixString(16).padLeft(5, '0');
    return 'sat-$millis-$suffix';
  }
}
