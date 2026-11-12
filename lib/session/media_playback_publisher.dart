import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:heming_platform/heming_platform.dart';

import 'session_controller.dart';

/// Mirrors the existing session into system media UI without owning playback.
class MediaPlaybackPublisher {
  MediaPlaybackPublisher({required this.session, required this.publish}) {
    session.addListener(_onChanged);
    _onChanged();
  }

  final SessionController session;
  final Future<void> Function(MediaPlaybackInfo) publish;
  MediaPlaybackInfo? _lastSent;
  Timer? _positionCooldown;
  bool _closed = false;
  Future<void>? _closing;

  MediaPlaybackInfo _snapshot() {
    final track = session.currentTrack;
    if (!session.membersLocked || track == null || session.taskId == null) {
      return MediaPlaybackInfo.idle;
    }
    final duration = track.durationMs.clamp(0, 0x7fffffffffffffff);
    final playing = session.phase == SessionPhase.playing;
    return MediaPlaybackInfo(
      active: true,
      taskId: session.taskId,
      title: track.title,
      phase: session.phase.name,
      durationMs: duration,
      positionMs: playing ? session.positionMs.clamp(0, duration) : 0,
      deviceCount: session.members.length,
      isMaster: session.isMaster,
      outputSuppressed: session.focusAttenuation < 1,
    );
  }

  Object _content(MediaPlaybackInfo info) => (
    info.active,
    info.taskId,
    info.title,
    info.phase,
    info.durationMs,
    info.deviceCount,
    info.isMaster,
    info.outputSuppressed,
  );

  void _onChanged() {
    if (_closed) return;
    final next = _snapshot();
    final previous = _lastSent;
    final contentChanged =
        previous == null || _content(previous) != _content(next);
    if (!contentChanged && previous.positionMs == next.positionMs) return;
    // State changes must reach native code before subsequent start/stop calls.
    // Only position is throttled, and the timer reads the latest session state.
    if (!contentChanged && _positionCooldown != null) return;
    _lastSent = next;
    _positionCooldown?.cancel();
    _positionCooldown = next.active
        ? Timer(const Duration(seconds: 1), () {
            _positionCooldown = null;
            _onChanged();
          })
        : null;
    // Do not queue sends behind previous responses: MethodChannel FIFO must
    // preserve metadata ordering relative to native service lifetime commands.
    unawaited(_publishSafely(next));
  }

  Future<void> _publishSafely(MediaPlaybackInfo info) async {
    try {
      await publish(info);
    } catch (error) {
      // A system UI failure must not stop audio or change group membership.
      debugPrint('Unable to update system playback status: $error');
    }
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    session.removeListener(_onChanged);
    _positionCooldown?.cancel();
    _positionCooldown = null;
    await _publishSafely(MediaPlaybackInfo.idle);
  }();
}
