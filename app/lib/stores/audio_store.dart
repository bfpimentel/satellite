import 'dart:async';
import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../audio_handler.dart';

enum AudioTrack { whiteNoise, rain }

extension AudioTrackExtension on AudioTrack {
  String get displayName {
    switch (this) {
      case AudioTrack.whiteNoise:
        return 'White Noise';
      case AudioTrack.rain:
        return 'Rain';
    }
  }

  String get assetPath {
    switch (this) {
      case AudioTrack.whiteNoise:
        return 'assets/white_noise.wav';
      case AudioTrack.rain:
        return 'assets/rain.mp3';
    }
  }
}

class AudioState {
  final String serverStatus;
  final bool isPlaying;
  final bool isWebSocketConnected;
  final AudioTrack selectedTrack;

  const AudioState({
    this.serverStatus = 'Not Configured',
    this.isPlaying = false,
    this.isWebSocketConnected = false,
    this.selectedTrack = AudioTrack.whiteNoise,
  });

  AudioState copyWith({
    String? serverStatus,
    bool? isPlaying,
    bool? isWebSocketConnected,
    AudioTrack? selectedTrack,
  }) {
    return AudioState(
      serverStatus: serverStatus ?? this.serverStatus,
      isPlaying: isPlaying ?? this.isPlaying,
      isWebSocketConnected: isWebSocketConnected ?? this.isWebSocketConnected,
      selectedTrack: selectedTrack ?? this.selectedTrack,
    );
  }
}

class AudioStore {
  static final AudioStore _instance = AudioStore._internal();
  factory AudioStore() => _instance;
  AudioStore._internal();

  AudioPlayer? _player;
  SatelliteAudioHandler? _audioHandler;
  WebSocketChannel? _statusChannel;
  StreamSubscription<dynamic>? _statusChannelSub;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _fallbackPollTimer;
  int _reconnectAttempt = 0;
  bool _assetLoaded = false;
  String _satelliteId = 'unknown';
  String _satelliteName = 'Unnamed Satellite';
  String? _serverUrl;

  final Signal<AudioState> state = signal(const AudioState());

  Stream<PlaybackState>? _playbackStateStream;

  void setAudioHandler(SatelliteAudioHandler handler) {
    _audioHandler = handler;
  }

  void setPlayer(AudioPlayer player) {
    _player = player;
    _player!.playerStateStream.listen((playerState) {
      state.value = state.value.copyWith(isPlaying: playerState.playing);
    });
  }

  Future<void> init() async {
    await _loadSelectedTrack();
  }

  Future<void> _loadSelectedTrack() async {
    final prefs = await SharedPreferences.getInstance();
    final trackName = prefs.getString('selected_track') ?? 'whiteNoise';
    final track = AudioTrack.values.firstWhere(
      (t) => t.name == trackName,
      orElse: () => AudioTrack.whiteNoise,
    );
    state.value = state.value.copyWith(selectedTrack: track);
    _audioHandler?.setTrack(track.assetPath, track.displayName);
  }

  Future<void> setTrack(AudioTrack track) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_track', track.name);
    state.value = state.value.copyWith(selectedTrack: track);

    // Update notification
    _audioHandler?.setTrack(track.assetPath, track.displayName);

    // Reload asset if track changes
    if (_assetLoaded) {
      _assetLoaded = false;
      await _player?.stop();
    }

    // Auto-play if server is currently playing
    if (state.value.serverStatus == 'Playing') {
      await play();
    }
  }

  void setSatelliteIdentity({required String id, required String name}) {
    _satelliteId = id;
    _satelliteName = name;
  }

  Future<void> setServerUrl(String url) async {
    _serverUrl = url;
    if (url.isEmpty) {
      state.value = state.value.copyWith(serverStatus: 'Not Configured');
      await _disconnectStatusSocket();
      await pause();
      return;
    }

    state.value = state.value.copyWith(serverStatus: 'Ready');
    _startHeartbeat();
    _startFallbackPoll();
    await _fetchStatusOnce();
    await _connectStatusSocket();
  }

  void _startFallbackPoll() {
    _fallbackPollTimer?.cancel();
    _fallbackPollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_serverUrl == null || _serverUrl!.isEmpty) return;
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
        '[Satellite heartbeat] status=${state.value.serverStatus} playing=${state.value.isPlaying} wsConnected=$wsConnected',
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
    if (_serverUrl == null || _serverUrl!.isEmpty) return;

    final nextState =
        state.value.serverStatus == 'Playing' ? 'Paused' : 'Playing';
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/status'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'state': nextState}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final newState = (jsonDecode(response.body)['state'] ?? '').toString();
        state.value = state.value.copyWith(
          serverStatus: newState.isEmpty ? 'Updating...' : newState,
        );
      } else {
        state.value = state.value.copyWith(serverStatus: 'Update Failed');
      }
    } catch (e) {
      state.value = state.value.copyWith(serverStatus: 'Update Failed');
    }
  }

  Future<void> _fetchStatusOnce() async {
    if (_serverUrl == null || _serverUrl!.isEmpty) return;
    try {
      final response = await http
          .get(Uri.parse('$_serverUrl/status'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        state.value = state.value.copyWith(
          serverStatus: 'Server Error (${response.statusCode})',
        );
        return;
      }
      final newState = (jsonDecode(response.body)['state'] ?? '').toString();
      await _applyServerState(newState);
    } catch (e) {
      state.value = state.value.copyWith(serverStatus: 'Server Unreachable');
      if (_player?.playing == true) {
        await pause();
      }
    }
  }

  Future<void> _connectStatusSocket() async {
    await _disconnectStatusSocket(stopHeartbeat: false);

    if (_serverUrl == null || _serverUrl!.isEmpty) return;

    final wsUri = _buildWebSocketStatusUri(_serverUrl!);
    if (wsUri == null) {
      state.value = state.value.copyWith(serverStatus: 'Invalid URL');
      return;
    }

    try {
      _statusChannel = WebSocketChannel.connect(wsUri);
      _reconnectAttempt = 0;
      state.value = state.value.copyWith(isWebSocketConnected: true);
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
            final newState = (data['state'] ?? '').toString();
            await _applyServerState(newState);
          } catch (_) {}
        },
        onDone: _handleSocketClosed,
        onError: (_) => _handleSocketClosed(),
      );
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _handleSocketClosed() {
    _statusChannel = null;
    _statusChannelSub = null;
    state.value = state.value.copyWith(isWebSocketConnected: false);
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
    state.value = state.value.copyWith(isWebSocketConnected: false);
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_serverUrl == null || _serverUrl!.isEmpty) return;
    _reconnectAttempt += 1;
    final delaySeconds = _reconnectAttempt > 6 ? 10 : _reconnectAttempt + 1;
    state.value = state.value.copyWith(serverStatus: 'Reconnecting...');
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      await _fetchStatusOnce();
      await _connectStatusSocket();
    });
  }

  Uri? _buildWebSocketStatusUri(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) return null;

    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/ws/status',
    );
  }

  Future<void> _applyServerState(String newState) async {
    debugPrint('Server state: $newState');
    if (newState == 'Playing') {
      if (_player?.playing != true) await play();
      state.value = state.value.copyWith(serverStatus: 'Playing');
    } else if (newState == 'Paused') {
      if (_player?.playing == true) await pause();
      state.value = state.value.copyWith(serverStatus: 'Paused');
    } else {
      state.value = state.value.copyWith(
        serverStatus: newState.isEmpty ? 'Unknown' : newState,
      );
    }
  }

  Future<void> play() async {
    final track = state.value.selectedTrack;
    if (!_assetLoaded) {
      await _player?.setAsset(track.assetPath);
      await _player?.setLoopMode(LoopMode.one);
      _assetLoaded = true;
    }
    await _player?.play();
  }

  Future<void> pause() async {
    await _player?.pause();
  }

  Future<void> stop() async {
    await _disconnectStatusSocket();
    await _player?.stop();
  }

  Stream<PlaybackState>? get playbackStateStream {
    _playbackStateStream ??= _player?.playerStateStream.map((playerState) {
      return PlaybackState(
        controls: const [
          MediaControl.play,
          MediaControl.pause,
          MediaControl.stop
        ],
        processingState: playerState.playing
            ? AudioProcessingState.ready
            : AudioProcessingState.idle,
        playing: playerState.playing,
      );
    });
    return _playbackStateStream;
  }
}
