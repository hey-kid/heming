import 'dart:async';
import 'dart:io';
import 'package:heming_audio/heming_audio.dart';
import 'package:heming_platform/heming_platform.dart';
import 'library_models.dart';

/// Native decoders handle WAV/MP3/FLAC. OS decoders supply audio from media containers.
class NativeMediaBackend implements MediaBackend {
  NativeMediaBackend(this.platform);
  final HemingPlatform platform;
  @override
  Future<AudioMetadata> inspect(
    String path, {
    bool verifyDecode = false,
  }) async {
    try {
      final info = await NativeMedia.probe(path, verifyDecode: verifyDecode);
      return AudioMetadata(
        codec: info.codec,
        sampleRate: info.sampleRate,
        channels: info.channels,
        bitsPerSample: info.bitsPerSample,
        durationMs: (info.durationSeconds * 1000).round(),
        verified: info.verified,
      );
    } catch (_) {
      // A canonical candidate must pass the native full decoder validation.
      if (verifyDecode) rethrow;
      final info = await platform.inspectMedia(path);
      return AudioMetadata(
        codec: info['codec'] as String? ?? 'unknown',
        sampleRate: (info['sampleRate'] as num?)?.toInt() ?? 0,
        channels: (info['channels'] as num?)?.toInt() ?? 0,
        bitsPerSample: (info['bitsPerSample'] as num?)?.toInt() ?? 0,
        durationMs:
            (((info['durationSeconds'] as num?)?.toDouble() ?? 0) * 1000)
                .round(),
      );
    }
  }

  @override
  Future<void> convert(
    String inputPath,
    String outputPath,
    ConversionToken token,
    void Function(double) onProgress,
  ) async {
    String source = inputPath;
    File? extracted;
    try {
      try {
        await NativeMedia.probe(inputPath);
      } catch (_) {
        token.throwIfCancelled();
        extracted = File('$outputPath.source.wav');
        token.onCancel = () {
          unawaited(platform.cancelMediaExtraction());
        };
        await platform.extractAudio(inputPath, extracted.path);
        token.onCancel = null;
        token.throwIfCancelled();
        source = extracted.path;
      }
      token.throwIfCancelled();
      final job = NativeMedia.convert(source, outputPath);
      token.onCancel = job.cancel;
      if (token.isCancelled) job.cancel();
      final timer = Timer.periodic(
        const Duration(milliseconds: 160),
        (_) => onProgress(job.progress),
      );
      try {
        await job.done;
        token.throwIfCancelled();
        onProgress(1);
      } finally {
        timer.cancel();
        token.onCancel = null;
      }
    } finally {
      token.onCancel = null;
      if (extracted != null && await extracted.exists()) {
        await extracted.delete();
      }
    }
  }
}
