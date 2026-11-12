import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'heming_audio_bindings.dart' as native;

export 'preview_player.dart';

class AudioException implements Exception {
  final String message;
  const AudioException(this.message);
  @override
  String toString() => message;
}

enum AudioState {
  idle,
  preparing,
  ready,
  scheduled,
  playing,
  completed,
  failed,
}

enum AudioChannel { stereo, left, right }

class AudioStatus {
  final AudioState state;
  final int bufferedFrames, playedFrames, totalFrames;
  final int clockOffsetMicros, clockRttMicros, audioPort;
  final int latencyCompensationMicros;
  final double driftPpm;
  final int hardwarePositionMicros,
      hardwareTimestampMicros,
      hardwareClockSource,
      hardwareRateWindows;
  final double hardwareRatePpm;
  final bool hardwareClockValid;
  final int outputUnderruns, outputSampleRate, callbackFrames;
  final int phaseErrorMicros;
  final String? error;
  final String? taskId;
  AudioStatus._(Map<String, dynamic> json, {this.taskId})
    : state = AudioState.values[json['state'] as int],
      bufferedFrames = json['bufferedFrames'] as int,
      playedFrames = json['playedFrames'] as int,
      totalFrames = json['totalFrames'] as int,
      clockOffsetMicros = json['clockOffsetMicros'] as int,
      clockRttMicros = json['clockRttMicros'] as int,
      latencyCompensationMicros = json['latencyCompensationMicros'] as int,
      audioPort = json['audioPort'] as int,
      driftPpm = (json['driftPpm'] as num).toDouble(),
      hardwarePositionMicros = json['hardwarePositionMicros'] as int,
      hardwareTimestampMicros = json['hardwareTimestampMicros'] as int,
      hardwareClockSource = json['hardwareClockSource'] as int,
      hardwareRateWindows = json['hardwareRateWindows'] as int,
      hardwareRatePpm = (json['hardwareRatePpm'] as num).toDouble(),
      hardwareClockValid = json['hardwareClockValid'] as bool,
      outputUnderruns = json['outputUnderruns'] as int,
      outputSampleRate = json['outputSampleRate'] as int,
      callbackFrames = json['callbackFrames'] as int,
      phaseErrorMicros = json['phaseErrorMicros'] as int,
      error = json['error'] == '' ? null : json['error'] as String?;
  double get bufferedSeconds => bufferedFrames / 48000;
  double get positionSeconds => playedFrames / 48000;
  double get durationSeconds => totalFrames / 48000;
}

Map<String, dynamic> _readJson(Pointer<Char> pointer) {
  if (pointer == nullptr) throw const AudioException('原生音频内存不足');
  try {
    return jsonDecode(pointer.cast<Utf8>().toDartString())
        as Map<String, dynamic>;
  } finally {
    native.hm_free(pointer.cast());
  }
}

/// Audio callbacks, sockets and media samples remain inside the native library.
/// All operations which initialize/tear down devices run off the UI isolate.
class NativeAudioEngine {
  final Pointer<Void> _handle;
  final _events = StreamController<AudioStatus>.broadcast();
  Timer? _timer;
  int _generation = 0;
  String? _statusTaskId;
  bool _disposed = false;
  Future<void> _operations = Future.value();
  NativeAudioEngine() : _handle = native.hm_create() {
    if (_handle == nullptr) throw const AudioException('无法创建音频内核');
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_disposed && _events.hasListener) _events.add(status);
    });
  }
  static int monotonicMicros() => native.hm_now_us();
  AudioStatus get status {
    _checkAlive();
    return AudioStatus._(
      _readJson(native.hm_status(_handle)),
      taskId: _statusTaskId,
    );
  }

  int get audioPort => status.audioPort;
  Stream<AudioStatus> get statuses => _events.stream;

  /// Adds a measured output-route delay to presentation-time prediction.
  /// A positive value schedules media earlier by that many microseconds.
  /// The setting survives stop/prepare and applies only to this engine.
  void setLatencyCompensationMicros(int microseconds) {
    _checkAlive();
    RangeError.checkValueInInterval(
      microseconds,
      -250000,
      250000,
      'microseconds',
    );
    native.hm_latency_compensation(_handle, microseconds);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('Audio engine has been disposed');
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final future = _operations.then((_) => operation());
    _operations = future.catchError((Object _) {});
    return future;
  }

  Future<void> prepareLocal({
    required String path,
    required String sessionId,
    required String taskId,
    int port = 0,
  }) async {
    _checkAlive();
    RangeError.checkValueInInterval(port, 0, 65535, 'port');
    final generation = ++_generation;
    _statusTaskId = null;
    final address = _handle.address;
    await _enqueue(
      () => Isolate.run(() {
        final p = path.toNativeUtf8();
        final s = sessionId.toNativeUtf8();
        final t = taskId.toNativeUtf8();
        try {
          final handle = Pointer<Void>.fromAddress(address);
          if (native.hm_prepare_local(
                handle,
                p.cast(),
                s.cast(),
                t.cast(),
                port,
              ) !=
              0) {
            throw AudioException(
              _readJson(native.hm_status(handle))['error'] as String,
            );
          }
        } finally {
          calloc.free(p);
          calloc.free(s);
          calloc.free(t);
        }
      }),
    );
    if (generation == _generation) _statusTaskId = taskId;
    await _waitReady(generation);
  }

  Future<void> prepareRemote({
    required String host,
    required int port,
    required String sessionId,
    required String taskId,
  }) async {
    _checkAlive();
    RangeError.checkValueInInterval(port, 1, 65535, 'port');
    final generation = ++_generation;
    _statusTaskId = null;
    final address = _handle.address;
    await _enqueue(
      () => Isolate.run(() {
        final h = host.toNativeUtf8();
        final s = sessionId.toNativeUtf8();
        final t = taskId.toNativeUtf8();
        try {
          final handle = Pointer<Void>.fromAddress(address);
          if (native.hm_prepare_remote(
                handle,
                h.cast(),
                port,
                s.cast(),
                t.cast(),
              ) !=
              0) {
            throw AudioException(
              _readJson(native.hm_status(handle))['error'] as String,
            );
          }
        } finally {
          calloc.free(h);
          calloc.free(s);
          calloc.free(t);
        }
      }),
    );
    if (generation == _generation) _statusTaskId = taskId;
    await _waitReady(generation);
  }

  Future<void> _waitReady(int generation) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!_disposed && generation == _generation) {
      final current = status;
      if (current.state == AudioState.ready) return;
      if (current.state == AudioState.failed) {
        throw AudioException(current.error ?? '音频准备失败');
      }
      if (DateTime.now().isAfter(deadline)) {
        await stop();
        throw const AudioException('音频准备超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    throw const AudioException('音频准备已取消');
  }

  void scheduleStart(int masterTimeUs) {
    _checkAlive();
    if (native.hm_schedule(_handle, masterTimeUs) != 0) {
      throw const AudioException('设备未就绪或预约开始时间已经过期');
    }
  }

  void setOutput({
    double volume = 1,
    AudioChannel channel = AudioChannel.stereo,
    bool muted = false,
  }) {
    _checkAlive();
    native.hm_output(_handle, volume.clamp(0, 1), channel.index, muted ? 1 : 0);
  }

  Future<void> stop() {
    _checkAlive();
    ++_generation;
    _statusTaskId = null;
    native.hm_interrupt(_handle);
    final address = _handle.address;
    return _enqueue(
      () =>
          Isolate.run(() => native.hm_stop(Pointer<Void>.fromAddress(address))),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    native.hm_interrupt(_handle);
    _timer?.cancel();
    final address = _handle.address;
    await _enqueue(
      () => Isolate.run(
        () => native.hm_destroy(Pointer<Void>.fromAddress(address)),
      ),
    );
    await _events.close();
  }
}

class MediaInfo {
  final String codec;
  final int sampleRate, channels, bitsPerSample, totalFrames;
  final bool verified;
  const MediaInfo({
    required this.codec,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.totalFrames,
    required this.verified,
  });
  double get durationSeconds => sampleRate == 0 ? 0 : totalFrames / sampleRate;
  bool get isCanonical =>
      codec == 'flac' &&
      sampleRate == 48000 &&
      channels == 2 &&
      bitsPerSample == 16;
  factory MediaInfo.fromJson(Map<String, dynamic> json) => MediaInfo(
    codec: json['codec'] as String,
    sampleRate: json['sampleRate'] as int,
    channels: json['channels'] as int,
    bitsPerSample: json['bitsPerSample'] as int,
    totalFrames: json['totalFrames'] as int,
    verified: json['verified'] as bool,
  );
}

abstract final class NativeMedia {
  static Future<MediaInfo> probe(
    String path, {
    bool verifyDecode = false,
  }) => Isolate.run(() {
    final p = path.toNativeUtf8();
    try {
      final json = _readJson(native.hm_probe(p.cast(), verifyDecode ? 1 : 0));
      if (json['error'] != null) throw AudioException(json['error'] as String);
      return MediaInfo.fromJson(json);
    } finally {
      calloc.free(p);
    }
  });
  static NativeConversion convert(String inputPath, String outputPath) {
    final input = inputPath.toNativeUtf8(), output = outputPath.toNativeUtf8();
    try {
      final handle = native.hm_convert(input.cast(), output.cast());
      if (handle == nullptr) throw const AudioException('转换目标必须是尚不存在的独立文件');
      return NativeConversion._(handle);
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }
}

class NativeConversion {
  final Pointer<Void> _handle;
  double _progress = 0;
  bool _finished = false;
  late final Future<void> done;
  NativeConversion._(this._handle) {
    done = _watch();
  }
  double get progress => _progress;
  void cancel() {
    if (!_finished) native.hm_conversion_cancel(_handle);
  }

  Future<void> _watch() async {
    try {
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final json = _readJson(native.hm_conversion_status(_handle));
        _progress = (json['progress'] as num).toDouble();
        final state = json['state'] as int;
        if (state == 1) return;
        if (state == 2 || state == 3) {
          throw AudioException(json['error'] as String);
        }
      }
    } finally {
      _finished = true;
      final address = _handle.address;
      await Isolate.run(
        () => native.hm_conversion_destroy(Pointer<Void>.fromAddress(address)),
      );
    }
  }
}
