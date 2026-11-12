import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:heming_audio/heming_audio.dart';
import 'package:test/test.dart';

Uint8List wav({int frames = 44100, int sampleRate = 44100}) {
  final bytes = Uint8List(44 + frames * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(i * 2 * pi * 440 / sampleRate) * 3000).round(),
      Endian.little,
    );
  }
  return bytes;
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('heming_media_');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'explicit conversion validates canonical FLAC and preserves source bytes',
    () async {
      final input = File('${directory.path}/原始音频.wav');
      final bytes = wav();
      await input.writeAsBytes(bytes);
      final metadata = await NativeMedia.probe(input.path);
      expect(metadata.codec, 'wav');
      expect(metadata.isCanonical, isFalse);
      expect(metadata.sampleRate, 44100);
      expect(metadata.verified, isFalse);
      final target = '${directory.path}/播放副本.flac';
      await NativeMedia.convert(input.path, target).done;
      final converted = await NativeMedia.probe(target, verifyDecode: true);
      expect(converted.isCanonical, isTrue);
      expect(converted.verified, isTrue);
      expect(converted.durationSeconds, closeTo(1, 0.005));
      expect(await input.readAsBytes(), bytes);
      // STREAMINFO total-samples=0 is legal; full validation still counts frames.
      final unknownLength = await File(target).readAsBytes();
      unknownLength[21] &= 0xf0;
      unknownLength.fillRange(22, 26, 0);
      final streamPath = '${directory.path}/stream.flac';
      await File(streamPath).writeAsBytes(unknownLength);
      expect((await NativeMedia.probe(streamPath)).totalFrames, 0);
      final counted = await NativeMedia.probe(streamPath, verifyDecode: true);
      expect(counted.isCanonical, isTrue);
      expect(counted.totalFrames, converted.totalFrames);
      expect(
        () => NativeMedia.convert(input.path, target),
        throwsA(isA<AudioException>()),
      );
    },
  );
  test('corrupt or renamed files cannot become playable', () async {
    final input = File('${directory.path}/not_audio.flac');
    await input.writeAsString('not a media file');
    await expectLater(
      NativeMedia.probe(input.path, verifyDecode: true),
      throwsA(isA<AudioException>()),
    );
  });
  test('cancel removes partial output while original remains', () async {
    final input = File('${directory.path}/long.wav');
    await input.writeAsBytes(wav(frames: 44100 * 20));
    final output = '${directory.path}/cancel.flac';
    final job = NativeMedia.convert(input.path, output);
    job.cancel();
    await expectLater(job.done, throwsA(isA<AudioException>()));
    expect(await File(output).exists(), isFalse);
    expect(await input.exists(), isTrue);
  });
  test('engine clock is monotonic and disposal invalidates handle', () async {
    final engine = NativeAudioEngine();
    final before = NativeAudioEngine.monotonicMicros();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(NativeAudioEngine.monotonicMicros(), greaterThan(before));
    expect(engine.status.state, AudioState.idle);
    engine.setLatencyCompensationMicros(250000);
    engine.setLatencyCompensationMicros(-250000);
    expect(() => engine.setLatencyCompensationMicros(250001), throwsRangeError);
    expect(
      () => engine.setLatencyCompensationMicros(-250001),
      throwsRangeError,
    );
    await engine.stop();
    expect(engine.status.latencyCompensationMicros, -250000);
    await engine.dispose();
    expect(() => engine.status, throwsStateError);
  });
}
