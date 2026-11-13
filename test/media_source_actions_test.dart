import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/media_scan.dart';
import 'package:heming/data/media_source_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test_media_source_actions');
  const actions = MediaSourceActions(channel: channel);
  final calls = <MethodCall>[];

  MediaScanEntry entry(String locator, {String category = 'audio'}) =>
      MediaScanEntry(
        sourceId: locator,
        locator: locator,
        name: category == 'video' ? '片段.mp4' : '歌曲.mp3',
        category: category,
        sizeBytes: 10,
        modifiedMs: 1,
      );

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'external opening forwards the exact authorized URI without copying',
    () async {
      const uri = 'content://media/external_primary/audio/media/42';
      await actions.open(entry(uri));
      expect(calls, hasLength(1));
      expect(calls.single.method, 'openMedia');
      expect(calls.single.arguments, {'locator': uri});
    },
  );

  test(
    'video opening stays a system action and never prepares a preview',
    () async {
      const uri = 'content://media/external/video/media/24';
      await actions.open(entry(uri, category: 'video'));
      expect(calls.map((call) => call.method), ['openMedia']);
    },
  );

  test('folder reveal forwards Unicode and spaces as one path', () async {
    const path = r'D:\本地音乐\夜间 歌曲 & 旋律.mp3';
    await actions.reveal(entry(path));
    expect(calls.single.method, 'revealMedia');
    expect(calls.single.arguments, {'locator': path});
  });

  test('invalid sources do not invoke a platform action', () async {
    for (final source in [
      entry(''),
      entry('file\u0000.mp3'),
      entry('tool.exe', category: 'executable'),
    ]) {
      await expectLater(actions.open(source), throwsFormatException);
    }
    expect(calls, isEmpty);
  });

  test('system errors remain available for the UI to explain', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: 'open_unavailable',
            message: '没有可打开此文件的播放器',
          );
        });
    await expectLater(
      actions.open(entry(r'C:\Music\track.mp3')),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.message,
          'message',
          '没有可打开此文件的播放器',
        ),
      ),
    );
  });
}
