import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final audioHandler = await AudioService.init(
    builder: () => SatelliteAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.satellite.app.playback',
      androidNotificationChannelName: 'Satellite Playback',
      androidNotificationIcon: 'drawable/ic_stat_satellite',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
  );
  runApp(SatelliteApp(audioHandler: audioHandler));
}

class SatelliteAudioHandler extends BaseAudioHandler {
  SatelliteAudioHandler() {
    mediaItem.add(
      const MediaItem(
        id: 'asset:///assets/white_noise.wav',
        album: 'Satellite',
        title: 'White Noise',
      ),
    );

    _player.playerStateStream.listen((state) {
      _emitPlaybackState(playing: state.playing, stopped: false);
      _emitUiState(status: _serverStatus, isPlaying: state.playing);
    });
  }

  final AudioPlayer _player = AudioPlayer();
  WebSocketChannel? _statusChannel;
  StreamSubscription<dynamic>? _statusChannelSub;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _fallbackPollTimer;
  int _reconnectAttempt = 0;
  String _serverStatus = 'Not Configured';
  String? _serverUrl;
  String _satelliteId = 'unknown';
  String _satelliteName = 'Unnamed Satellite';
  bool _assetLoaded = false;

  void setSatelliteIdentity({required String id, required String name}) {
    _satelliteId = id;
    _satelliteName = name;
  }

  Future<void> setServerUrl(String url) async {
    _serverUrl = url;
    if (url.isEmpty) {
      _serverStatus = 'Not Configured';
      await _disconnectStatusSocket();
      await pause();
      _emitUiState(status: _serverStatus, isPlaying: _player.playing);
      return;
    }

    _serverStatus = 'Ready';
    _emitUiState(status: _serverStatus, isPlaying: _player.playing);
    _startHeartbeat();
    _startFallbackPoll();
    await _fetchStatusOnce();
    await _connectStatusSocket();
  }

  void _startFallbackPoll() {
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_serverUrl == null || _serverUrl!.isEmpty) {
        return;
      }
      if (_statusChannel == null) {
        await _fetchStatusOnce();
      }
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final wsConnected = _statusChannel != null;
      debugPrint(
        '[Satellite heartbeat] status=$_serverStatus playing=${_player.playing} wsConnected=$wsConnected',
      );
      if (wsConnected) {
        _statusChannel!.sink.add(
          jsonEncode({
            'type': 'ping',
            'id': _satelliteId,
            'name': _satelliteName,
          }),
        );
      }
    });
  }

  Future<void> toggleServerStatus() async {
    if (_serverUrl == null || _serverUrl!.isEmpty) {
      return;
    }

    final nextState = _serverStatus == 'Playing' ? 'Paused' : 'Playing';
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/status'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'state': nextState}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final state = (jsonDecode(response.body)['state'] ?? '').toString();
        _serverStatus = state.isEmpty ? 'Updating...' : state;
      } else {
        _serverStatus = 'Update Failed';
      }
      _emitUiState(status: _serverStatus, isPlaying: _player.playing);
    } catch (e) {
      _serverStatus = 'Update Failed';
      _emitUiState(status: _serverStatus, isPlaying: _player.playing);
    }
  }

  Future<void> _fetchStatusOnce() async {
    if (_serverUrl == null || _serverUrl!.isEmpty) {
      return;
    }
    try {
      final response = await http
          .get(Uri.parse('$_serverUrl/status'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        _serverStatus = 'Server Error (${response.statusCode})';
        _emitUiState(status: _serverStatus, isPlaying: _player.playing);
        return;
      }
      final state = (jsonDecode(response.body)['state'] ?? '').toString();
      await _applyServerState(state);
    } catch (e) {
      _serverStatus = 'Server Unreachable';
      if (_player.playing) {
        await pause();
      }
      _emitUiState(status: _serverStatus, isPlaying: _player.playing);
    }
  }

  Future<void> _connectStatusSocket() async {
    await _disconnectStatusSocket(stopHeartbeat: false);

    if (_serverUrl == null || _serverUrl!.isEmpty) {
      return;
    }

    final wsUri = _buildWebSocketStatusUri(_serverUrl!);
    if (wsUri == null) {
      _serverStatus = 'Invalid URL';
      _emitUiState(status: _serverStatus, isPlaying: _player.playing);
      return;
    }

    try {
      _statusChannel = WebSocketChannel.connect(wsUri);
      _reconnectAttempt = 0;
      _statusChannel!.sink.add(
        jsonEncode({
          'type': 'hello',
          'role': 'satellite',
          'id': _satelliteId,
          'name': _satelliteName,
        }),
      );
      _statusChannelSub = _statusChannel!.stream.listen(
        (message) async {
          try {
            final data = jsonDecode(message.toString());
            final state = (data['state'] ?? '').toString();
            await _applyServerState(state);
          } catch (_) {}
        },
        onDone: _handleSocketClosed,
        onError: (_) => _handleSocketClosed(),
      );
      _emitUiState(status: _serverStatus, isPlaying: _player.playing);
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _handleSocketClosed() {
    _statusChannel = null;
    _statusChannelSub = null;
    _scheduleReconnect();
  }

  Future<void> _disconnectStatusSocket({bool stopHeartbeat = true}) async {
    if (stopHeartbeat) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _fallbackPollTimer?.cancel();
      _fallbackPollTimer = null;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _statusChannelSub?.cancel();
    _statusChannelSub = null;
    await _statusChannel?.sink.close();
    _statusChannel = null;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_serverUrl == null || _serverUrl!.isEmpty) {
      return;
    }
    _reconnectAttempt += 1;
    final delaySeconds = _reconnectAttempt > 6 ? 10 : _reconnectAttempt + 1;
    _serverStatus = 'Reconnecting...';
    _emitUiState(status: _serverStatus, isPlaying: _player.playing);
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      await _fetchStatusOnce();
      await _connectStatusSocket();
    });
  }

  Uri? _buildWebSocketStatusUri(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/ws/status',
    );
  }

  Future<void> _applyServerState(String state) async {
    debugPrint('Server state: $state');
    if (state == 'Playing') {
      if (!_player.playing) {
        await play();
      }
      _serverStatus = 'Playing';
    } else if (state == 'Paused') {
      if (_player.playing) {
        await pause();
      }
      _serverStatus = 'Paused';
    } else {
      _serverStatus = state.isEmpty ? 'Unknown' : state;
    }
    _emitUiState(status: _serverStatus, isPlaying: _player.playing);
  }

  @override
  Future<void> play() async {
    if (!_assetLoaded) {
      await _player.setAsset('assets/white_noise.wav');
      await _player.setLoopMode(LoopMode.one);
      _assetLoaded = true;
    }
    await _player.play();
    _emitPlaybackState(playing: true, stopped: false);
    _emitUiState(status: _serverStatus, isPlaying: true);
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emitPlaybackState(playing: false, stopped: false);
    _emitUiState(status: _serverStatus, isPlaying: false);
  }

  @override
  Future<void> stop() async {
    await _disconnectStatusSocket();
    await _player.stop();
    _emitPlaybackState(playing: false, stopped: true);
    _emitUiState(status: _serverStatus, isPlaying: false);
    return super.stop();
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'setServerUrl') {
      await setServerUrl((extras?['url'] ?? '').toString());
      return;
    }
    return super.customAction(name, extras);
  }

  void _emitPlaybackState({required bool playing, required bool stopped}) {
    playbackState.add(
      PlaybackState(
        controls: const [
          MediaControl.play,
          MediaControl.pause,
          MediaControl.stop
        ],
        processingState:
            stopped ? AudioProcessingState.idle : AudioProcessingState.ready,
        playing: playing,
      ),
    );
  }

  void _emitUiState({required String status, required bool isPlaying}) {
    customState.add({'status': status, 'isPlaying': isPlaying});
  }
}

class SatelliteApp extends StatelessWidget {
  const SatelliteApp({required this.audioHandler, super.key});

  final SatelliteAudioHandler audioHandler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Satellite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: HomePage(audioHandler: audioHandler),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({required this.audioHandler, super.key});

  final SatelliteAudioHandler audioHandler;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _serverUrl = '';
  String _satelliteName = 'Unnamed Satellite';
  String _satelliteId = '';
  bool _hasPermissions = false;
  String _status = 'Not Configured';
  bool _isPlaying = false;
  bool _isConfigured = false;
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  StreamSubscription<dynamic>? _handlerStateSub;

  @override
  void initState() {
    super.initState();
    _handlerStateSub = widget.audioHandler.customState.listen((state) {
      if (!mounted || state is! Map) {
        return;
      }
      setState(() {
        _status = (state['status'] ?? _status).toString();
        _isPlaying = state['isPlaying'] == true;
      });
    });
    _loadServerUrl();
    _checkPermissions();
  }

  @override
  void dispose() {
    _handlerStateSub?.cancel();
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url') ?? '';
    final name = prefs.getString('satellite_name') ?? 'Unnamed Satellite';
    final id = prefs.getString('satellite_id') ?? _generateSatelliteId();
    await prefs.setString('satellite_id', id);
    setState(() {
      _serverUrl = url;
      _satelliteName = name;
      _satelliteId = id;
      _isConfigured = url.isNotEmpty;
      _urlController.text = url;
      _nameController.text = name;
    });
    widget.audioHandler
        .setSatelliteIdentity(id: _satelliteId, name: _satelliteName);
    if (_isConfigured) {
      await widget.audioHandler.setServerUrl(_serverUrl);
    }
  }

  String _generateSatelliteId() {
    final random = Random();
    final millis = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final suffix = random.nextInt(1 << 20).toRadixString(16).padLeft(5, '0');
    return 'sat-$millis-$suffix';
  }

  Future<void> _saveConfiguration(String url, String satelliteName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
    await prefs.setString('satellite_name', satelliteName);
    setState(() {
      _serverUrl = url;
      _satelliteName = satelliteName;
      _isConfigured = url.isNotEmpty;
      if (_isConfigured) {
        _status = 'Ready';
      }
    });
    widget.audioHandler
        .setSatelliteIdentity(id: _satelliteId, name: _satelliteName);
    if (_isConfigured) {
      await widget.audioHandler.setServerUrl(_serverUrl);
    }
  }

  Future<void> _checkPermissions() async {
    final notifications = await Permission.notification.status.isGranted;
    setState(() => _hasPermissions = notifications);
  }

  Future<void> _requestPermissions() async {
    await [Permission.notification].request();
    await _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isConfigured) {
      return _buildSetupScreen();
    }
    return _buildMainScreen();
  }

  Widget _buildSetupScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SATELLITE',
          style: TextStyle(fontWeight: FontWeight.w300, letterSpacing: 4),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            const Text(
              'SETUP',
              style:
                  TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter the server URL to connect to',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                labelText: 'Server URL',
                labelStyle: TextStyle(color: Colors.grey),
                hintText: 'http://192.168.1.100:5000',
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                labelText: 'Satellite Name',
                labelStyle: TextStyle(color: Colors.grey),
                hintText: 'Bedroom Speaker',
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white)),
              ),
            ),
            const Spacer(),
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: () => _saveConfiguration(
                  _urlController.text.trim(),
                  _nameController.text.trim().isEmpty
                      ? 'Unnamed Satellite'
                      : _nameController.text.trim(),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                child: const Text(
                  'SAVE',
                  style:
                      TextStyle(letterSpacing: 2, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildMainScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SATELLITE',
          style: TextStyle(fontWeight: FontWeight.w300, letterSpacing: 4),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            const Text(
              'SERVER STATUS',
              style:
                  TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              _status.toUpperCase(),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 48),
            const Text(
              'PLAYBACK',
              style:
                  TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              _isPlaying ? 'PLAYING' : 'STOPPED',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
                color: _isPlaying ? Colors.white : Colors.grey,
              ),
            ),
            const Spacer(),
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: () => widget.audioHandler.toggleServerStatus(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                child: Text(
                  _status == 'Playing' ? 'REQUEST PAUSE' : 'REQUEST PLAY',
                  style: const TextStyle(
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!_hasPermissions) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration:
                    BoxDecoration(border: Border.all(color: Colors.white)),
                child: const Column(
                  children: [
                    Text(
                      'BACKGROUND PERMISSIONS REQUIRED',
                      style: TextStyle(fontSize: 12, letterSpacing: 2),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Go to Android Settings > Apps > Satellite > Battery > Allow background activity',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (!_hasPermissions) ...[
              OutlinedButton(
                onPressed: _requestPermissions,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white),
                  padding: const EdgeInsets.symmetric(vertical: 20),
                ),
                child: const Text(
                  'REQUEST PERMISSIONS',
                  style: TextStyle(letterSpacing: 2),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'SATELLITE: ${_satelliteName.toUpperCase()}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                letterSpacing: 2,
                color: Colors.grey,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('server_url');
                await prefs.remove('satellite_name');
                await widget.audioHandler.setServerUrl('');
                setState(() {
                  _isConfigured = false;
                  _status = 'Not Configured';
                  _isPlaying = false;
                });
              },
              child: const Text(
                'CHANGE SERVER URL',
                style: TextStyle(letterSpacing: 2, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
