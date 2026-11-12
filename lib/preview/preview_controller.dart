import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/library_models.dart';

enum PreviewState { idle, loading, paused, playing, completed, failed }

class PreviewStatus {
  const PreviewStatus(
    this.state, {
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
  });
  final PreviewState state;
  final int positionMs, durationMs;
  final String? error;
}

abstract interface class PreviewAudioPort {
  Stream<PreviewStatus> get statuses;
  PreviewStatus get status;
  Future<void> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(int positionMs);
  Future<void> stop();
  void setVolume(double volume);
  Future<void> dispose();
}

/// A foreground-only local player. It never creates a room or a network task.
class PreviewController extends ChangeNotifier {
  PreviewController({
    required this._audio,
    required this._canPlay,
    required this._acquireFocus,
    required this._releaseFocus,
  }) {
    _subscription = _audio.statuses.listen(
      _onStatus,
      onError: (Object failure) {
        _failFromEvent('试听播放中断，请重试。');
      },
    );
  }
  final PreviewAudioPort _audio;
  final bool Function() _canPlay;
  final Future<bool> Function() _acquireFocus;
  final Future<void> Function() _releaseFocus;
  late final StreamSubscription<PreviewStatus> _subscription;
  Future<void> _operations = Future<void>.value();
  Future<void>? _closing;
  Timer? _completionTimer;
  int _generation = 0, _focusRevision = 0;
  bool _closed = false, _acceptStatus = false, _focusPaused = false;
  bool _completedFocusReleased = false;
  double _volume = 1, _attenuation = 1;
  String? itemId;
  PreviewState state = PreviewState.idle;
  int positionMs = 0, durationMs = 0;
  String? error;
  bool get isActive => itemId != null;

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.catchError((Object _) {});
    return next;
  }

  bool _current(int generation) =>
      !_closed &&
      generation == _generation &&
      state != PreviewState.failed &&
      _canPlay();
  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _cancelCompletion() {
    _completionTimer?.cancel();
    _completionTimer = null;
  }

  // Stop reaches the native epoch interrupt immediately. Its completion is
  // awaited in order, so old cleanup cannot close a newly opened resource.
  // Capture early errors as values until their queued waiter can consume them.
  Future<Object?> _beginStop() {
    try {
      return _audio.stop().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
    } catch (error) {
      return Future<Object?>.value(error);
    }
  }

  Future<void> _releaseSafely() async {
    try {
      await _releaseFocus();
    } catch (error) {
      debugPrint('Unable to release preview audio focus: $error');
    }
  }

  Future<void> _finishStop(Future<Object?> stopping) async {
    try {
      final failure = await stopping;
      if (failure != null) {
        debugPrint('Unable to stop preview output: $failure');
      }
    } finally {
      await _releaseSafely();
    }
  }

  Future<Object?>? _prepareFailure(int generation, String message) {
    if (_closed ||
        generation != _generation ||
        itemId == null ||
        (state == PreviewState.failed && !_acceptStatus)) {
      return null;
    }
    _acceptStatus = false;
    _focusPaused = false;
    ++_focusRevision;
    _cancelCompletion();
    state = PreviewState.failed;
    error = message;
    final stopping = _beginStop();
    _notify();
    return stopping;
  }

  void _failFromEvent(String message) {
    final stopping = _prepareFailure(_generation, message);
    if (stopping != null) unawaited(_enqueue(() => _finishStop(stopping)));
  }

  Future<void> _failOperation(int generation, String message) async {
    final stopping = _prepareFailure(generation, message);
    if (stopping != null) await _finishStop(stopping);
  }

  void _onStatus(PreviewStatus status) {
    if (!_acceptStatus || _closed || itemId == null) return;
    if (status.state == PreviewState.failed) {
      _failFromEvent(status.error ?? '音频解码失败，请检查文件或重试。');
      return;
    }
    state = status.state;
    positionMs = status.positionMs;
    durationMs = status.durationMs;
    error = status.error;
    if (state != PreviewState.completed) {
      _cancelCompletion();
    } else if (!_completedFocusReleased && _completionTimer == null) {
      final generation = _generation;
      // Let the final native output buffer drain before relinquishing focus.
      _completionTimer = Timer(const Duration(milliseconds: 250), () {
        _completionTimer = null;
        unawaited(
          _enqueue(() async {
            if (!_closed &&
                generation == _generation &&
                state == PreviewState.completed &&
                !_completedFocusReleased) {
              _completedFocusReleased = true;
              await _releaseSafely();
            }
          }),
        );
      });
    }
    _notify();
  }

  Future<void> play(LibraryItem item) {
    if (_closed || !_canPlay()) return Future<void>.value();
    final generation = ++_generation;
    ++_focusRevision;
    _acceptStatus = false;
    _focusPaused = false;
    _completedFocusReleased = false;
    _cancelCompletion();
    _attenuation = 1;
    itemId = item.id;
    state = PreviewState.loading;
    positionMs = 0;
    durationMs = item.durationMs;
    error = null;
    final stopping = _beginStop();
    _notify();
    return _enqueue(() async {
      await _finishStop(stopping);
      if (!_current(generation)) return;
      try {
        if (!await _acquireFocus()) {
          await _failOperation(generation, '暂时无法获得音频输出，请稍后重试。');
          return;
        }
        if (!_current(generation)) return;
        try {
          await _audio.open(item.originalPath);
        } catch (_) {
          if (!_current(generation)) return;
          final fallback = item.playablePath;
          if (fallback == null || fallback == item.originalPath) rethrow;
          await _audio.open(fallback);
        }
        if (!_current(generation)) return;
        _audio.setVolume(_volume * _attenuation);
        await _audio.play();
        if (!_current(generation)) return;
        _acceptStatus = true;
        _onStatus(_audio.status);
      } catch (_) {
        await _failOperation(
          generation,
          '无法试听此文件。可直接试听 WAV、MP3、FLAC，其他格式请转换后重试。',
        );
      }
    });
  }

  Future<void> togglePause() {
    final generation = _generation;
    final pause = state == PreviewState.playing;
    _focusPaused = false;
    ++_focusRevision;
    _cancelCompletion();
    return _enqueue(() async {
      if (!_current(generation)) return;
      try {
        if (pause && state == PreviewState.playing) {
          await _audio.pause();
        } else if (!pause &&
            (state == PreviewState.paused || state == PreviewState.completed)) {
          _attenuation = 1;
          if (!await _acquireFocus()) return;
          if (!_current(generation)) return;
          _completedFocusReleased = false;
          _audio.setVolume(_volume * _attenuation);
          await _audio.play();
        }
        if (_current(generation)) _onStatus(_audio.status);
      } catch (_) {
        await _failOperation(generation, '试听播放中断，请重试。');
      }
    });
  }

  Future<void> seek(int positionMs) {
    final generation = _generation;
    _cancelCompletion();
    return _enqueue(() async {
      if (!_current(generation) ||
          ![
            PreviewState.playing,
            PreviewState.paused,
            PreviewState.completed,
          ].contains(state)) {
        return;
      }
      try {
        await _audio.seek(positionMs.clamp(0, durationMs));
        if (_current(generation)) _onStatus(_audio.status);
      } catch (_) {
        await _failOperation(generation, '此音频无法跳转到所选位置，请重试。');
      }
    });
  }

  void _applyVolume() {
    if (_closed) return;
    try {
      _audio.setVolume(_volume * _attenuation);
    } catch (_) {
      _failFromEvent('无法调整试听音量，请重试。');
    }
  }

  void setVolume(double volume) {
    _volume = volume.clamp(0, 1);
    _applyVolume();
  }

  void setFocusAttenuation(double attenuation) {
    ++_focusRevision;
    _attenuation = attenuation.clamp(0, 1);
    _applyVolume();
  }

  Future<void> focusLost() {
    if (_closed) return Future<void>.value();
    final generation = _generation;
    final revision = ++_focusRevision;
    _focusPaused =
        state == PreviewState.playing || state == PreviewState.loading;
    _attenuation = 0;
    _applyVolume();
    return _enqueue(() async {
      if (!_current(generation) ||
          revision != _focusRevision ||
          state != PreviewState.playing) {
        return;
      }
      try {
        await _audio.pause();
        if (_current(generation)) _onStatus(_audio.status);
      } catch (_) {
        await _failOperation(generation, '无法暂停试听，请重试。');
      }
    });
  }

  Future<void> focusGained() {
    if (_closed) return Future<void>.value();
    final generation = _generation;
    final revision = ++_focusRevision;
    // Apply gain now: a newer duck must not be undone after a pending open.
    _attenuation = 1;
    _applyVolume();
    return _enqueue(() async {
      if (!_current(generation) ||
          revision != _focusRevision ||
          !_focusPaused) {
        return;
      }
      _focusPaused = false;
      if (state != PreviewState.paused) return;
      try {
        await _audio.play();
        if (_current(generation)) _onStatus(_audio.status);
      } catch (_) {
        await _failOperation(generation, '试听播放中断，请重试。');
      }
    });
  }

  Future<void> stop() {
    if (_closing != null) return _closing!;
    ++_generation;
    ++_focusRevision;
    _acceptStatus = false;
    _focusPaused = false;
    _cancelCompletion();
    itemId = null;
    state = PreviewState.idle;
    positionMs = durationMs = 0;
    error = null;
    final stopping = _beginStop();
    _notify();
    return _enqueue(() => _finishStop(stopping));
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final stopping = stop();
    return _closing = _close(stopping);
  }

  Future<void> _close(Future<void> stopping) async {
    try {
      await stopping;
    } finally {
      try {
        await _subscription.cancel();
      } finally {
        try {
          await _audio.dispose();
        } finally {
          super.dispose();
        }
      }
    }
  }
}
