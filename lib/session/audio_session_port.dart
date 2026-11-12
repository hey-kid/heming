import '../shared/models.dart';

enum PlaybackAudioState {
  idle,
  preparing,
  ready,
  scheduled,
  playing,
  completed,
  failed,
}

class PlaybackAudioStatus {
  const PlaybackAudioStatus({
    required this.state,
    this.bufferedFrames = 0,
    this.playedFrames = 0,
    this.totalFrames = 0,
    this.clockOffsetMicros = 0,
    this.clockRttMicros = 0,
    this.error,
    this.taskId,
  });
  final PlaybackAudioState state;
  final int bufferedFrames;
  final int playedFrames;
  final int totalFrames;
  final int clockOffsetMicros;
  final int clockRttMicros;
  final String? error;

  /// Identity captured when sampled, so a delayed event cannot advance a new song.
  final String? taskId;
}

class AudioPreparation {
  const AudioPreparation({required this.port, required this.totalFrames});
  final int port;
  final int totalFrames;
}

abstract class AudioSessionPort {
  int get monotonicMicros;
  Stream<PlaybackAudioStatus> get statuses;
  Future<AudioPreparation> prepareMaster(
    PlayableTrack track, {
    required String sessionId,
    required String taskId,
  });
  Future<void> prepareFollower({
    required String host,
    required int port,
    required String sessionId,
    required String taskId,
  });
  void scheduleStart(int masterTimeUs);
  Future<void> stop();
  void setOutput({
    required double volume,
    required AudioChannel channel,
    required bool muted,
  });
  Future<void> dispose();
}
