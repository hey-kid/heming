import 'package:heming_audio/heming_audio.dart' as native;

import 'preview_controller.dart';

class NativePreviewAudioPort implements PreviewAudioPort {
  NativePreviewAudioPort() : _player = native.NativePreviewPlayer();
  final native.NativePreviewPlayer _player;
  PreviewStatus _map(native.PreviewAudioStatus status) => PreviewStatus(
    PreviewState.values.byName(status.state.name),
    positionMs: status.positionMs,
    durationMs: status.durationMs,
    error: status.error,
  );
  @override
  Stream<PreviewStatus> get statuses => _player.statuses.map(_map);
  @override
  PreviewStatus get status => _map(_player.status);
  @override
  Future<void> open(String path) => _player.open(path);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(int positionMs) => _player.seek(positionMs);
  @override
  Future<void> stop() => _player.stop();
  @override
  void setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> dispose() => _player.dispose();
}
