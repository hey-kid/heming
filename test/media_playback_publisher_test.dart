import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/session/media_playback_publisher.dart';
import 'package:heming/session/session_controller.dart';
import 'package:heming_platform/heming_platform.dart';

class _UnusedAudio implements AudioSessionPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Media UI must not call audio: ${invocation.memberName}',
  );
}

class _DisplaySession extends SessionController {
  _DisplaySession()
    : super(audio: _UnusedAudio(), deviceId: 'local', deviceName: '本机');

  SessionPhase displayPhase = SessionPhase.standby;
  PlayableTrack? track;
  String? task;
  int position = 0;
  double attenuation = 1;
  bool master = true;
  @override
  SessionPhase get phase => displayPhase;
  @override
  bool get membersLocked => [
    SessionPhase.preparing,
    SessionPhase.scheduled,
    SessionPhase.playing,
  ].contains(displayPhase);
  @override
  PlayableTrack? get currentTrack => track;
  @override
  String? get taskId => task;
  @override
  int get positionMs => position;
  @override
  double get focusAttenuation => attenuation;
  @override
  bool get isMaster => master;
  @override
  List<DeviceMember> get members => [
    localDevice,
    const DeviceMember(
      id: 'other',
      name: '另一台',
      platform: 'test',
      address: '',
      port: 0,
    ),
  ];
  void change() => notifyListeners();
}

const _first = PlayableTrack(
  id: 'one',
  title: '第一首',
  path: 'one.flac',
  durationMs: 20000,
);
const _second = PlayableTrack(
  id: 'two',
  title: '第二首',
  path: 'two.flac',
  durationMs: 5000,
);

void main() {
  testWidgets('preparation, playing, focus suppression and stop are mirrored', (
    tester,
  ) async {
    final session = _DisplaySession();
    final updates = <MediaPlaybackInfo>[];
    final publisher = MediaPlaybackPublisher(
      session: session,
      publish: (info) async => updates.add(info),
    );
    expect(updates.single.active, isFalse);
    session
      ..track = _first
      ..task = 'task-one'
      ..position = 19000
      ..displayPhase = SessionPhase.preparing
      ..change();
    expect(updates.last.title, '第一首');
    expect(updates.last.durationMs, 20000);
    expect(updates.last.positionMs, 0);
    expect(updates.last.phase, 'preparing');
    expect(updates.last.deviceCount, 2);
    expect(updates.last.isMaster, isTrue);
    session
      ..displayPhase = SessionPhase.scheduled
      ..change();
    expect(updates.last.phase, 'scheduled');
    expect(updates.last.positionMs, 0);
    session
      ..displayPhase = SessionPhase.playing
      ..position = 3200
      ..change();
    expect(updates.last.positionMs, 3200);
    session
      ..attenuation = 0
      ..change();
    expect(updates.last.phase, 'playing');
    expect(updates.last.positionMs, 3200);
    expect(updates.last.outputSuppressed, isTrue);
    expect(session.task, 'task-one');
    session
      ..attenuation = 1
      ..master = false
      ..change();
    expect(updates.last.outputSuppressed, isFalse);
    expect(updates.last.isMaster, isFalse);
    session
      ..displayPhase = SessionPhase.standby
      ..change();
    expect(updates.last.toMap(), MediaPlaybackInfo.idle.toMap());
    await publisher.close();
  });

  testWidgets('progress is throttled but a new task resets immediately', (
    tester,
  ) async {
    final session = _DisplaySession()
      ..track = _first
      ..task = 'task-one'
      ..displayPhase = SessionPhase.playing;
    final updates = <MediaPlaybackInfo>[];
    final publisher = MediaPlaybackPublisher(
      session: session,
      publish: (info) async => updates.add(info),
    );
    for (var frame = 1; frame <= 9; frame++) {
      session
        ..position = frame * 100
        ..change();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(updates, hasLength(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(updates, hasLength(2));
    expect(updates.last.positionMs, 900);
    session
      ..position = 19000
      ..change();
    session
      ..track = _second
      ..task = 'task-two'
      ..displayPhase = SessionPhase.preparing
      ..change();
    expect(updates, hasLength(3));
    expect(updates.last.title, '第二首');
    expect(updates.last.taskId, 'task-two');
    expect(updates.last.positionMs, 0);
    session
      ..displayPhase = SessionPhase.playing
      ..change();
    expect(updates.last.positionMs, 5000);
    await publisher.close();
    final count = updates.length;
    session
      ..position = 1000
      ..change();
    await tester.pump(const Duration(seconds: 2));
    expect(updates, hasLength(count));
    expect(updates.last.active, isFalse);
  });

  testWidgets(
    'slow native replies never queue an old active update after stop',
    (tester) async {
      final session = _DisplaySession()
        ..track = _first
        ..task = 'task-one'
        ..displayPhase = SessionPhase.playing;
      final delayedReply = Completer<void>();
      final updates = <MediaPlaybackInfo>[];
      final publisher = MediaPlaybackPublisher(
        session: session,
        publish: (info) {
          updates.add(info);
          return info.active ? delayedReply.future : Future.value();
        },
      );
      session
        ..displayPhase = SessionPhase.standby
        ..change();
      expect(updates.map((info) => info.active), [true, false]);
      await publisher.close();
      delayedReply.complete();
      await tester.pump(const Duration(seconds: 2));
      expect(updates.map((info) => info.active), [true, false, false]);
    },
  );

  testWidgets('native UI failures do not alter the playback session', (
    tester,
  ) async {
    final session = _DisplaySession()
      ..track = _first
      ..task = 'task-one'
      ..displayPhase = SessionPhase.playing;
    var attempts = 0;
    final publisher = MediaPlaybackPublisher(
      session: session,
      publish: (info) {
        attempts++;
        if (attempts == 1) throw StateError('sync UI failure');
        return Future.error(StateError('async UI failure'));
      },
    );
    session
      ..attenuation = 0
      ..change();
    await tester.pump();
    expect(session.phase, SessionPhase.playing);
    expect(session.taskId, 'task-one');
    expect(attempts, 2);
    await publisher.close();
  });
}
