import 'dart:convert';
import 'dart:io';
import 'package:heming_audio/heming_audio.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('Usage: dart run tool/media_convert.dart INPUT NEW_OUTPUT.flac');
    exitCode = 64;
    return;
  }
  await NativeMedia.convert(args[0], args[1]).done;
  final info = await NativeMedia.probe(args[1], verifyDecode: true);
  stdout.writeln(jsonEncode({
    'codec': info.codec,
    'sampleRate': info.sampleRate,
    'channels': info.channels,
    'bitsPerSample': info.bitsPerSample,
    'totalFrames': info.totalFrames,
    'verified': info.verified,
  }));
}
