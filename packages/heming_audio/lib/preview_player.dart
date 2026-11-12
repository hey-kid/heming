import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'heming_audio_bindings.dart' as native;

enum PreviewAudioState { idle, loading, paused, playing, completed, failed }

class PreviewAudioStatus {
  final PreviewAudioState state;
  final int positionMs;
  final int durationMs;
  final String? error;

  const PreviewAudioStatus({
    this.state = PreviewAudioState.idle,
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
  });

  factory PreviewAudioStatus._fromJson(Map<String, dynamic> json) =>
      PreviewAudioStatus(
        state: PreviewAudioState.values[json['state'] as int],
        positionMs: json['positionMs'] as int,
        durationMs: json['durationMs'] as int,
        error: json['error'] as String?,
      );
}

class PreviewAudioException implements Exception {
  final String message;
  const PreviewAudioException(this.message);

  @override
  String toString() => message;
}

PreviewAudioStatus _readPreviewStatus(Pointer<Void> handle) {
  final pointer = native.hm_preview_status(handle);
  if (pointer == nullptr) {
    throw const PreviewAudioException('无法读取预览播放状态');
  }
  try {
    return PreviewAudioStatus._fromJson(
      jsonDecode(pointer.cast<Utf8>().toDartString()) as Map<String, dynamic>,
    );
  } finally {
    native.hm_free(pointer.cast());
  }
}

// Only primitive arguments cross the isolate boundary. In particular a player,
// timer, event controller, or an open native resource is never sent to an isolate.
PreviewAudioStatus _previewOperation(
  int address,
  String operation,
  int epoch,
  String? path,
  int positionMs,
) {
  final handle = Pointer<Void>.fromAddress(address);
  var result = 0;
  switch (operation) {
    case 'open':
      final encoded = path!.toNativeUtf8();
      try {
        result = native.hm_preview_open(handle, encoded.cast());
      } finally {
        calloc.free(encoded);
      }
    case 'play':
      result = native.hm_preview_play(handle, epoch);
    case 'pause':
      native.hm_preview_pause(handle);
    case 'seek':
      result = native.hm_preview_seek(handle, positionMs, epoch);
    case 'stop':
      native.hm_preview_stop(handle);
  }
  final status = _readPreviewStatus(handle);
  if (result < 0) {
    throw PreviewAudioException(status.error ?? '预览播放失败');
  }
  if (result > 0) throw const PreviewAudioException('预览已取消');
  return status;
}

// Keep isolate closures in top-level functions: nesting one in _command's
// instance closure would capture its shared lexical context (including Timer).
Future<PreviewAudioStatus> _dispatchPreviewOperation(
  int address,
  String operation,
  int epoch,
  String? path,
  int positionMs,
) => Isolate.run(
  () => _previewOperation(address, operation, epoch, path, positionMs),
);

Future<void> _destroyPreview(int address) => Isolate.run(
  () => native.hm_preview_destroy(Pointer<Void>.fromAddress(address)),
);

/// A streaming, local-only WAV/MP3/FLAC player, independent of group playback.
///
/// [open] prepares one file paused. [play] resumes, or restarts a completed file.
/// [seek] uses milliseconds and preserves playing/paused state. File/device work
/// is serialized off the UI isolate. Stop invalidates pending starts immediately.
class NativePreviewPlayer {
  final Pointer<Void> _handle = native.hm_preview_create();
  final _events = StreamController<PreviewAudioStatus>.broadcast();
  Future<void> _operations = Future<void>.value();
  Future<void>? _disposal;
  Timer? _timer;
  Timer? _drainTimer;
  PreviewAudioStatus _status = const PreviewAudioStatus();
  bool _disposed = false;
  bool _opening = false;
  int _generation = 0;
  int _epoch = 1;

  NativePreviewPlayer() {
    if (_handle == nullptr) {
      throw const PreviewAudioException('无法创建预览播放器');
    }
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_disposed || _opening) return;
      final current = _readPreviewStatus(_handle);
      _emit(current);
      if (current.state == PreviewAudioState.completed && _drainTimer == null) {
        // Allow queued output to drain before stopping an otherwise silent
        // device. Never stop or release a device from inside its own callback.
        final generation = _generation;
        _drainTimer = Timer(const Duration(milliseconds: 250), () {
          if (!_disposed &&
              generation == _generation &&
              _status.state == PreviewAudioState.completed) {
            unawaited(_command('pause').catchError((Object _) {}));
          }
        });
      }
    });
  }

  Stream<PreviewAudioStatus> get statuses => _events.stream;
  PreviewAudioStatus get status => _status;

  void _checkAlive() {
    if (_disposed) throw StateError('Preview player has been disposed');
  }

  void _emit(PreviewAudioStatus value) {
    if (_disposed) return;
    _status = value;
    _events.add(value);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final future = _operations.then((_) => operation());
    _operations = future.catchError((Object _) {});
    return future;
  }

  void _cancelDrain() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  Future<void> _command(String operation, {String? path, int positionMs = 0}) {
    final address = _handle.address;
    final epoch = _epoch;
    final generation = _generation;
    return _enqueue(() async {
      if (_disposed || generation != _generation) return;
      try {
        final value = await _dispatchPreviewOperation(
          address,
          operation,
          epoch,
          path,
          positionMs,
        );
        if (!_disposed && generation == _generation) {
          if (operation == 'open') _opening = false;
          _emit(value);
        }
      } catch (error) {
        if (!_disposed && generation == _generation) {
          _opening = false;
          _emit(_readPreviewStatus(_handle));
          rethrow;
        }
      }
    });
  }

  Future<void> open(String path) {
    _checkAlive();
    ++_generation;
    _epoch = native.hm_preview_interrupt(_handle);
    _cancelDrain();
    _opening = true;
    _emit(const PreviewAudioStatus(state: PreviewAudioState.loading));
    return _command('open', path: path);
  }

  Future<void> play() {
    _checkAlive();
    _cancelDrain();
    return _command('play');
  }

  Future<void> pause() {
    _checkAlive();
    _epoch = native.hm_preview_interrupt(_handle);
    _cancelDrain();
    return _command('pause');
  }

  Future<void> seek(int positionMs) {
    _checkAlive();
    _cancelDrain();
    return _command('seek', positionMs: positionMs.clamp(0, 0x7fffffffffff));
  }

  void setVolume(double volume) {
    _checkAlive();
    if (!volume.isFinite) throw ArgumentError.value(volume, 'volume');
    native.hm_preview_volume(_handle, volume.clamp(0, 1));
  }

  Future<void> stop() {
    _checkAlive();
    ++_generation;
    _epoch = native.hm_preview_interrupt(_handle);
    _opening = true;
    _cancelDrain();
    _emit(const PreviewAudioStatus());
    return _command('stop').whenComplete(() {
      if (!_disposed && _status.state == PreviewAudioState.idle) {
        _opening = false;
      }
    });
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    ++_generation;
    native.hm_preview_interrupt(_handle);
    _timer?.cancel();
    _cancelDrain();
    final address = _handle.address;
    return _disposal = _enqueue(() async {
      await _destroyPreview(address);
      await _events.close();
    });
  }
}
