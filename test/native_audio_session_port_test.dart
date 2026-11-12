import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/session/native_audio_session_port.dart';
import 'package:heming_audio/heming_audio.dart' as native;
import 'package:heming_platform/heming_platform.dart';

class _Engine implements native.NativeAudioEngine {
  final preparedTasks = <String>[];
  int stops = 0;

  @override
  Future<void> prepareRemote({
    required String host,
    required int port,
    required String sessionId,
    required String taskId,
  }) async {
    preparedTasks.add(taskId);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements HemingPlatform {
  final firstPreparation = Completer<int?>();
  final completed = <(int?, bool)>[];
  var preparations = 0;

  @override
  Future<int?> beginNativeOutputPreparation() async {
    preparations++;
    return preparations == 1 ? firstPreparation.future : preparations;
  }

  @override
  Future<void> endNativeOutputPreparation(
    int? token, {
    required bool success,
  }) async {
    completed.add((token, success));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a late Android output preparation cannot replace audio after a switch',
    () async {
      final engine = _Engine();
      final platform = _Platform();
      final port = NativeAudioSessionPort(engine: engine, platform: platform);
      final first = port.prepareFollower(
        host: '127.0.0.1',
        port: 12345,
        sessionId: 'session',
        taskId: 'old',
      );
      final cancelled = expectLater(first, throwsStateError);
      await port.stop();
      await port.prepareFollower(
        host: '127.0.0.1',
        port: 12345,
        sessionId: 'session',
        taskId: 'latest',
      );
      expect(engine.preparedTasks, ['latest']);
      platform.firstPreparation.complete(1);
      await cancelled;
      expect(engine.preparedTasks, ['latest']);
      expect(engine.stops, 1);
      expect(platform.completed, containsAll([(2, true), (1, false)]));
    },
  );
}
