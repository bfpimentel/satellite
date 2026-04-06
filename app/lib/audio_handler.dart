import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

class SatelliteAudioHandler extends BaseAudioHandler {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _playerStateSubscription;
  bool _assetLoaded = false;
  String _currentTrackId = 'assets/white_noise.wav';
  String _currentTrackTitle = 'White Noise';

  SatelliteAudioHandler() {
    _updateMediaItem();

    _playerStateSubscription = _player.playerStateStream.listen((state) {
      _updatePlaybackState(state.playing);
    });
  }

  void _updateMediaItem() {
    mediaItem.add(
      MediaItem(
        id: 'asset:///$_currentTrackId',
        album: 'Satellite',
        title: _currentTrackTitle,
      ),
    );
  }

  void setTrack(String assetPath, String title) {
    if (_currentTrackId != assetPath) {
      _currentTrackId = assetPath;
      _currentTrackTitle = title;
      _assetLoaded = false;
      _updateMediaItem();
    }
  }

  void _updatePlaybackState(bool isPlaying) {
    playbackState.add(
      PlaybackState(
        controls: const [
          MediaControl.play,
          MediaControl.pause,
          MediaControl.stop,
        ],
        processingState: AudioProcessingState.ready,
        playing: isPlaying,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (!_assetLoaded) {
      await _player.setAsset(_currentTrackId);
      await _player.setLoopMode(LoopMode.one);
      _assetLoaded = true;
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    _playerStateSubscription?.cancel();
    await _player.stop();
    await super.stop();
  }

  AudioPlayer get player => _player;
}
