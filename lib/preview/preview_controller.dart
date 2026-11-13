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

/// A read-only playable source. Only temporary sources provide [release].
class PreparedPreviewSource {
  PreparedPreviewSource({
    required this.path,
    this.fallbackPath,
    this._release,
  });

  final String path;
  final String? fallbackPath;
  final Future<void> Function()? _release;
  Future<void>? _releasing;

  Future<void> release() =>
      _releasing ??= Future<void>.sync(() async => await _release?.call());
}

class PreviewSourceFailure implements Exception {
  const PreviewSourceFailure(this.message);
  final String message;
}

/// Cancellation completes the waiter immediately. A source arriving afterwards
/// was never opened and can be released without waiting for the player's queue.
class _PreviewPreparation {
  _PreviewPreparation(this.prepare, this.cancelPrepare);
  final Future<PreparedPreviewSource> Function() prepare;
  final Future<void> Function()? cancelPrepare;
  final _result = Completer<PreparedPreviewSource?>();
  bool _started = false;
  Future<void>? _cancelling;

  Future<PreparedPreviewSource?> start() {
    if (_result.isCompleted) return _result.future;
    _started = true;
    Future<PreparedPreviewSource>.sync(prepare).then(
      (source) {
        if (_result.isCompleted) {
          unawaited(
            source.release().catchError((Object error) {
              debugPrint('Unable to release cancelled preview source: $error');
            }),
          );
        } else {
          _result.complete(source);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_result.isCompleted) _result.completeError(error, stack);
      },
    );
    return _result.future;
  }

  Future<void> cancel() {
    if (!_result.isCompleted) _result.complete(null);
    return _cancelling ??=
        Future<void>.sync(() async {
          if (_started) await cancelPrepare?.call();
        }).catchError((Object error) {
          debugPrint('Unable to cancel preview preparation: $error');
        });
  }
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
  _PreviewPreparation? _preparation;
  PreparedPreviewSource? _source;
  int _generation = 0, _focusRevision = 0;
  bool _closed = false, _acceptStatus = false, _focusPaused = false;
  bool _completedFocusReleased = false;
  double _volume = 1, _attenuation = 1;
  String? itemId;
  PreviewState state = PreviewState.idle;
  int positionMs = 0, durationMs = 0;
  String? error;
  bool get isActive => itemId != null;
  bool get allowed => !_closed && _canPlay();

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

  Future<void> _finishStop(
    Future<Object?> stopping, {
    Future<void>? cancellation,
  }) async {
    try {
      final failure = await stopping;
      if (failure != null) {
        debugPrint('Unable to stop preview output: $failure');
      }
    } finally {
      await cancellation;
      final source = _source;
      _source = null;
      try {
        await source?.release();
      } catch (error) {
        debugPrint('Unable to release preview source: $error');
      } finally {
        await _releaseSafely();
      }
    }
  }

  Future<void>? _cancelPreparation() {
    final pending = _preparation;
    _preparation = null;
    return pending?.cancel();
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
    unawaited(_cancelPreparation());
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

  Future<void> play(LibraryItem item) => playSource(
    id: item.id,
    durationMs: item.durationMs,
    prepare: () async => PreparedPreviewSource(
      path: item.originalPath,
      fallbackPath: item.playablePath,
    ),
    failureMessage: '无法试听此文件。可直接试听 WAV、MP3、FLAC，其他格式请转换后重试。',
  );

  /// Reserves the shared player before asynchronously preparing a scan source.
  /// The existing app-wide stop/background/room guards cover preparation too.
  Future<void> playSource({
    required String id,
    required Future<PreparedPreviewSource> Function() prepare,
    Future<void> Function()? cancelPrepare,
    int durationMs = 0,
    String failureMessage = '暂时无法预览此音频，可尝试用其他播放器打开。',
  }) {
    if (_closed || !_canPlay()) return Future<void>.value();
    final cancellation = _cancelPreparation();
    final preparation = _PreviewPreparation(prepare, cancelPrepare);
    _preparation = preparation;
    final generation = ++_generation;
    ++_focusRevision;
    _acceptStatus = false;
    _focusPaused = false;
    _completedFocusReleased = false;
    _cancelCompletion();
    _attenuation = 1;
    itemId = id;
    state = PreviewState.loading;
    positionMs = 0;
    this.durationMs = durationMs;
    error = null;
    final stopping = _beginStop();
    _notify();
    return _enqueue(() async {
      await _finishStop(stopping, cancellation: cancellation);
      if (!_current(generation)) return;
      try {
        final source = await preparation.start();
        if (identical(_preparation, preparation)) _preparation = null;
        if (source == null) return;
        _source = source;
        if (!_current(generation)) {
          await _finishStop(_beginStop());
          return;
        }
        if (!await _acquireFocus()) {
          await _failOperation(generation, '暂时无法获得音频输出，请稍后重试。');
          return;
        }
        if (!_current(generation)) return;
        try {
          await _audio.open(source.path);
        } catch (_) {
          if (!_current(generation)) return;
          final fallback = source.fallbackPath;
          if (fallback == null || fallback == source.path) rethrow;
          await _audio.open(fallback);
        }
        if (!_current(generation)) return;
        _audio.setVolume(_volume * _attenuation);
        await _audio.play();
        if (!_current(generation)) return;
        _acceptStatus = true;
        _onStatus(_audio.status);
      } catch (failure) {
        if (identical(_preparation, preparation)) _preparation = null;
        await _failOperation(
          generation,
          failure is PreviewSourceFailure ? failure.message : failureMessage,
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
    final cancellation = _cancelPreparation();
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
    return _enqueue(() => _finishStop(stopping, cancellation: cancellation));
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
