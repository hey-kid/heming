import 'package:heming_audio/heming_audio.dart' as native;
import 'package:heming_platform/heming_platform.dart';

import '../shared/models.dart';
import 'audio_session_port.dart';

class NativeAudioSessionPort implements AudioSessionPort {
  NativeAudioSessionPort({native.NativeAudioEngine? engine, this.platform})
    : _engine = engine ?? native.NativeAudioEngine();
  final native.NativeAudioEngine _engine;
  final HemingPlatform? platform;
  int _preparationGeneration = 0;

  Future<void> _prepareOutput(Future<void> Function() prepare) async {
    final generation = ++_preparationGeneration;
    final token = await platform?.beginNativeOutputPreparation();
    var success = false;
    try {
      if (generation != _preparationGeneration) {
        throw StateError('音频准备已取消');
      }
      await prepare();
      if (generation != _preparationGeneration) {
        throw StateError('音频准备已取消');
      }
      success = true;
    } finally {
      await platform?.endNativeOutputPreparation(token, success: success);
    }
  }

  @override
  int get monotonicMicros => native.NativeAudioEngine.monotonicMicros();

  @override
  Stream<PlaybackAudioStatus> get statuses => _engine.statuses
      .where((status) => status.taskId != null)
      .map(
        (status) => PlaybackAudioStatus(
          state: PlaybackAudioState.values.byName(status.state.name),
          bufferedFrames: status.bufferedFrames,
          playedFrames: status.playedFrames,
          totalFrames: status.totalFrames,
          clockOffsetMicros: status.clockOffsetMicros,
          clockRttMicros: status.clockRttMicros,
          error: status.error,
          taskId: status.taskId,
        ),
      );

  @override
  Future<AudioPreparation> prepareMaster(
    PlayableTrack track, {
    required String sessionId,
    required String taskId,
  }) async {
    await _prepareOutput(
      () => _engine.prepareLocal(
        path: track.path,
        sessionId: sessionId,
        taskId: taskId,
      ),
    );
    return AudioPreparation(
      port: _engine.audioPort,
      totalFrames: _engine.status.totalFrames,
    );
  }

  @override
  Future<void> prepareFollower({
    required String host,
    required int port,
    required String sessionId,
    required String taskId,
  }) => _prepareOutput(
    () => _engine.prepareRemote(
      host: host,
      port: port,
      sessionId: sessionId,
      taskId: taskId,
    ),
  );

  @override
  void scheduleStart(int masterTimeUs) => _engine.scheduleStart(masterTimeUs);

  @override
  Future<void> stop() {
    _preparationGeneration++;
    return _engine.stop();
  }

  @override
  void setOutput({
    required double volume,
    required AudioChannel channel,
    required bool muted,
  }) => _engine.setOutput(
    volume: volume,
    channel: native.AudioChannel.values.byName(channel.name),
    muted: muted,
  );

  @override
  Future<void> dispose() {
    _preparationGeneration++;
    return _engine.dispose();
  }
}
