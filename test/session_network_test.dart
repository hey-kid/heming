import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/session/session_controller.dart';

class FakeAudio implements AudioSessionPort {
  final _events = StreamController<PlaybackAudioStatus>.broadcast(sync: true);
  final clock = Stopwatch()..start();
  Completer<void>? gate;
  Completer<void>? stopGate;
  Object? preparationError;
  int schedules = 0;
  int stops = 0;
  String? preparedTask;
  double volume = 1;
  AudioChannel channel = AudioChannel.stereo;
  bool muted = false;
  @override
  int get monotonicMicros => clock.elapsedMicroseconds;
  @override
  Stream<PlaybackAudioStatus> get statuses => _events.stream;
  void emit(PlaybackAudioState state, {String? error, String? taskId}) =>
      _events.add(
        PlaybackAudioStatus(
          state: state,
          bufferedFrames: 240000,
          totalFrames: 480000,
          error: error,
          taskId: taskId ?? preparedTask,
        ),
      );
  @override
  Future<AudioPreparation> prepareMaster(
    PlayableTrack track, {
    required String sessionId,
    required String taskId,
  }) async {
    preparedTask = taskId;
    if (preparationError != null) throw preparationError!;
    if (gate != null) await gate!.future;
    emit(PlaybackAudioState.ready);
    return const AudioPreparation(port: 30000, totalFrames: 480000);
  }

  @override
  Future<void> prepareFollower({
    required String host,
    required int port,
    required String sessionId,
    required String taskId,
  }) async {
    preparedTask = taskId;
    if (gate != null) await gate!.future;
    emit(PlaybackAudioState.ready);
  }

  @override
  void scheduleStart(int masterTimeUs) {
    schedules++;
    emit(PlaybackAudioState.scheduled);
  }

  @override
  Future<void> stop() async {
    stops++;
    final pending = stopGate;
    stopGate = null;
    if (pending != null) await pending.future;
  }

  @override
  void setOutput({
    required double volume,
    required AudioChannel channel,
    required bool muted,
  }) {
    this.volume = volume;
    this.channel = channel;
    this.muted = muted;
  }

  @override
  Future<void> dispose() => _events.close();
}

Future<void> eventually(bool Function() condition, {String? reason}) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 4)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

const trackA = PlayableTrack(
  id: 'a',
  title: 'A',
  path: 'a.flac',
  durationMs: 10000,
);
const trackB = PlayableTrack(
  id: 'b',
  title: 'B',
  path: 'b.flac',
  durationMs: 10000,
);
const unplayable = PlayableTrack(
  id: 'c',
  title: 'C',
  path: 'c.mp3',
  durationMs: 10000,
  isPlayable: false,
);

void main() {
  final controllers = <SessionController>[];
  Future<SessionController> device(
    String id, {
    FakeAudio? audio,
    Future<bool> Function(PlayableTrack)? validator,
    Duration prepareTimeout = const Duration(seconds: 3),
    Duration heartbeatTimeout = const Duration(seconds: 2),
    Future<bool> Function()? acquireAudioFocus,
    Future<bool> Function()? resumeAudioFocus,
    Future<void> Function()? releaseAudioFocus,
    Future<void> Function(bool)? setPlaybackActive,
  }) async {
    final result = SessionController(
      audio: audio ?? FakeAudio(),
      deviceId: id,
      deviceName: id,
      platformName: 'test',
      enableDiscovery: false,
      heartbeatInterval: const Duration(milliseconds: 100),
      heartbeatTimeout: heartbeatTimeout,
      prepareTimeout: prepareTimeout,
      startLead: const Duration(milliseconds: 50),
      validateTrack: validator ?? (_) async => true,
      acquireAudioFocus: acquireAudioFocus,
      resumeAudioFocus: resumeAudioFocus,
      releaseAudioFocus: releaseAudioFocus,
      setPlaybackActive: setPlaybackActive,
    );
    controllers.add(result);
    await result.initialize(port: 0);
    return result;
  }

  Future<void> connect(
    SessionController master,
    SessionController follower,
  ) async {
    await follower.join('127.0.0.1', port: master.serverPort);
    await eventually(
      () => master.pendingJoins.any((r) => r.id == follower.localDevice.id),
    );
    master.approveJoin(follower.localDevice.id);
    await eventually(() => follower.isConnected);
  }

  tearDown(() async {
    for (final controller in controllers.reversed) {
      await controller.shutdown();
    }
    controllers.clear();
  });

  test(
    'full queue and next-track mode synchronize without replacing current task',
    () async {
      final masterAudio = FakeAudio();
      final followerAudio = FakeAudio();
      final master = await device('queue-master', audio: masterAudio);
      final follower = await device('queue-follower', audio: followerAudio);
      await master.createRoom();
      await connect(master, follower);
      final tracks = [trackA, unplayable, trackB];
      await master.startPlaylist(tracks, startIndex: 2);
      await eventually(() => followerAudio.schedules == 1);
      tracks.clear();
      expect(master.queue.map((t) => t.id), ['a', 'b']);
      expect(follower.queue.map((t) => t.id), ['a', 'b']);
      expect(follower.queueIndex, 1);
      expect(master.canNextTrack, isFalse);
      expect(master.canPreviousTrack, isTrue);
      final task = master.taskId;
      final stops = masterAudio.stops;
      master.setPlaybackMode(PlaybackMode.random);
      await eventually(() => follower.playbackMode == PlaybackMode.random);
      expect(master.modeChangePending, isTrue);
      expect(follower.modeChangePending, isTrue);
      expect(master.taskId, task);
      expect(follower.taskId, task);
      expect(masterAudio.stops, stops);
      expect(master.canNextTrack, isTrue);
      await follower.nextTrack();
      await follower.previousTrack();
      await follower.selectQueueTrack(0);
      follower.setPlaybackMode(PlaybackMode.sequential);
      expect(follower.taskId, task);
      expect(follower.playbackMode, PlaybackMode.random);
      await master.nextTrack();
      await eventually(() => followerAudio.schedules == 2);
      expect(master.queueIndex, 0);
      expect(follower.queueIndex, 0);
      expect(follower.taskId, master.taskId);
      expect(master.modeChangePending, isFalse);
      expect(follower.modeChangePending, isFalse);
      expect(master.canNextTrack, isFalse);
      expect(master.canPreviousTrack, isTrue);
      await master.previousTrack();
      await eventually(() => followerAudio.schedules == 3);
      expect(master.queueIndex, 1);
      expect(follower.queueIndex, 1);
      expect(master.canNextTrack, isTrue);
      await master.nextTrack();
      await eventually(() => followerAudio.schedules == 4);
      expect(master.queueIndex, 0);
    },
  );

  test(
    'random consumes each unplayed item once and previous follows actual history',
    () async {
      final audio = FakeAudio();
      final master = await device('shuffle', audio: audio);
      final tracks = List.generate(
        8,
        (i) => PlayableTrack(
          id: 'shuffle-$i',
          title: '歌曲 $i',
          path: '$i.flac',
          durationMs: 10000,
        ),
      );
      await master.createRoom();
      expect(master.playbackMode, PlaybackMode.sequential);
      master.setPlaybackMode(PlaybackMode.random);
      await master.startPlaylist(tracks);
      final history = [master.queueIndex];
      while (master.canNextTrack) {
        await master.nextTrack();
        history.add(master.queueIndex);
      }
      expect(history.length, tracks.length);
      expect(history.toSet().length, tracks.length);
      for (var i = history.length - 2; i >= 0; i--) {
        await master.previousTrack();
        expect(master.queueIndex, history[i]);
      }
      expect(master.canPreviousTrack, isFalse);
      for (var i = 1; i < history.length; i++) {
        await master.nextTrack();
        expect(master.queueIndex, history[i]);
      }
      final lastTask = master.taskId;
      await master.nextTrack();
      expect(master.taskId, lastTask);
      audio.emit(PlaybackAudioState.completed);
      await eventually(() => master.phase == SessionPhase.standby);
      expect(master.queue, isEmpty);
      expect(master.currentTrack, isNull);
      expect(master.canNextTrack, isFalse);
      expect(master.canPreviousTrack, isFalse);
    },
  );

  test(
    'oversized or ineligible replacement preserves a task still preparing',
    () async {
      final audio = FakeAudio();
      final validationGate = Completer<bool>();
      var checks = 0;
      final master = await device(
        'bounded-queue',
        audio: audio,
        validator: (_) async {
          checks++;
          return checks == 2 ? validationGate.future : true;
        },
      );
      final starting = master.play(trackA);
      await eventually(() => master.currentTrack?.id == 'a');
      final originalTask = master.taskId;
      await master.startPlaylist([unplayable]);
      expect(master.taskId, originalTask);
      final oversized = List.generate(
        600,
        (i) => PlayableTrack(
          id: 'large-$i',
          title: '歌曲名称' * 50,
          path: '$i.flac',
          durationMs: 10000,
        ),
      );
      await master.startPlaylist(oversized);
      expect(master.taskId, originalTask);
      expect(master.error, contains('播放列表过长'));
      validationGate.complete(true);
      await starting;
      expect(master.phase, SessionPhase.scheduled);
      expect(master.currentTrack?.id, 'a');
      expect(audio.schedules, 1);
    },
  );

  test(
    'sequential starts at selected row and ends after last with no wrap',
    () async {
      final audio = FakeAudio();
      final master = await device('ordered', audio: audio);
      await master.startPlaylist([trackA, trackB], startIndex: 1);
      expect(master.queueIndex, 1);
      expect(master.canNextTrack, isFalse);
      expect(master.canPreviousTrack, isTrue);
      final task = master.taskId;
      await master.nextTrack();
      expect(master.taskId, task);
      await master.previousTrack();
      expect(master.queueIndex, 0);
      expect(master.canPreviousTrack, isFalse);
      await master.nextTrack();
      expect(master.queueIndex, 1);
      await master.selectQueueTrack(0);
      expect(master.currentTrack?.id, 'a');
      audio.emit(PlaybackAudioState.completed);
      await eventually(
        () =>
            master.currentTrack?.id == 'b' &&
            master.phase == SessionPhase.scheduled,
      );
      audio.emit(PlaybackAudioState.completed);
      await eventually(() => master.phase == SessionPhase.standby);
    },
  );

  test(
    'previous from a selected sequential row follows queue and preserves a pending mode',
    () async {
      final master = await device('previous-mode');
      final tracks = List.generate(
        4,
        (i) => PlayableTrack(
          id: 'row-$i',
          title: '第 $i 首',
          path: '$i.flac',
          durationMs: 10000,
        ),
      );
      await master.startPlaylist(tracks, startIndex: 2);
      expect(master.canPreviousTrack, isTrue);
      master.setPlaybackMode(PlaybackMode.random);
      await master.previousTrack();
      expect(master.queueIndex, 1);
      expect(master.modeChangePending, isTrue);
      await master.previousTrack();
      expect(master.queueIndex, 0);
      expect(master.canPreviousTrack, isFalse);
      expect(master.modeChangePending, isTrue);
      await master.nextTrack();
      // Rows 0, 1 and 2 have played; random must choose the only remaining row.
      expect(master.queueIndex, 3);
      expect(master.modeChangePending, isFalse);
      await master.previousTrack();
      expect(master.queueIndex, 0);
      master.setPlaybackMode(PlaybackMode.sequential);
      await master.previousTrack();
      // Still random until Next: previous walks 3 -> 0 -> 1 in actual history.
      expect(master.queueIndex, 1);
      expect(master.modeChangePending, isTrue);
      await master.nextTrack();
      expect(master.queueIndex, 2);
      expect(master.modeChangePending, isFalse);
    },
  );

  test(
    'rapid selection, delayed validation and stale completion never replace the latest task',
    () async {
      final audio = FakeAudio();
      Completer<bool>? validation;
      final master = await device(
        'rapid',
        audio: audio,
        validator: (track) async {
          if (track.id == 'b' && validation != null) return validation.future;
          return true;
        },
      );
      await master.startPlaylist([trackA, trackB]);
      final originalTask = master.taskId;
      validation = Completer<bool>();
      final waiting = master.nextTrack();
      await eventually(() => master.currentTrack?.id == 'b');
      final abandonedTask = master.taskId;
      await master.selectQueueTrack(0);
      final latestTask = master.taskId;
      audio.emit(PlaybackAudioState.completed, taskId: originalTask);
      audio.emit(PlaybackAudioState.failed, taskId: abandonedTask);
      expect(master.taskId, latestTask);
      expect(master.currentTrack?.id, 'a');
      validation.complete(true);
      await waiting;
      expect(master.taskId, latestTask);
      expect(audio.schedules, 2);
      await master.endPlayback();
      audio.emit(PlaybackAudioState.completed, taskId: latestTask);
      await master.nextTrack();
      expect(master.phase, SessionPhase.standby);
      expect(master.queue, isEmpty);
    },
  );

  test(
    'follower ignores stale queue revisions and previous-session messages',
    () async {
      final audio = FakeAudio();
      final follower = await device('queue-client', audio: audio);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? socket;
      final messages = <Map<String, dynamic>>[];
      void send(String type, Map<String, Object?> payload) => socket!.add(
        jsonEncode({
          'v': 1,
          'type': type,
          'sessionId': 'queue-session',
          ...payload,
        }),
      );
      server.listen((request) async {
        socket = await WebSocketTransformer.upgrade(request);
        socket!.listen((dynamic payload) {
          final message = jsonDecode(payload as String) as Map<String, dynamic>;
          messages.add(message);
          if (message['type'] == 'join') {
            send('welcome', {
              'masterId': 'wire-master',
              'members': [
                const DeviceMember(
                  id: 'wire-master',
                  name: 'master',
                  platform: 'test',
                  address: '127.0.0.1',
                  port: 12345,
                ).toJson(),
                follower.localDevice.toJson(),
              ],
            });
          } else if (message['type'] == 'ping') {
            send('pong', {});
          }
        });
      });
      addTearDown(() async {
        await socket?.close();
        await server.close(force: true);
      });
      await follower.join('127.0.0.1', port: server.port);
      await eventually(() => follower.isConnected);
      Map<String, Object?> snapshot(int revision, int index) => {
        'queueRevision': revision,
        'queue': [trackA.toWire(), trackB.toWire()],
        'queueIndex': index,
        'playbackMode': 'sequential',
        'activePlaybackMode': 'sequential',
        'skippedCount': 0,
      };
      send('reset_task', {
        'taskId': 'old-task',
        'track': trackA.toWire(),
        ...snapshot(1, 0),
      });
      await eventually(() => follower.taskId == 'old-task');
      send('reset_task', {
        'taskId': 'new-task',
        'track': trackB.toWire(),
        ...snapshot(2, 1),
      });
      send('prepare', {'taskId': 'new-task', 'audioPort': 30000});
      await eventually(
        () => messages.any(
          (m) => m['type'] == 'ready' && m['taskId'] == 'new-task',
        ),
      );
      send('start', {'taskId': 'new-task', 'startTimeUs': 1000});
      await eventually(() => follower.phase == SessionPhase.scheduled);
      send('reset_task', {
        'taskId': 'old-task',
        'track': trackA.toWire(),
        ...snapshot(1, 0),
      });
      send('queue_state', {'taskId': 'new-task', ...snapshot(1, 0)});
      send('queue_state', {
        'taskId': 'new-task',
        ...snapshot(3, 0),
        'sessionId': 'old-session',
      });
      send('queue_state', {'taskId': 'old-task', ...snapshot(4, 0)});
      send('stop', {'taskId': 'old-task'});
      // An ordered marker proves that all the preceding frames were handled.
      send('notice', {'reason': 'marker'});
      await eventually(() => follower.message == 'marker');
      expect(follower.taskId, 'new-task');
      expect(follower.queueIndex, 1);
      expect(follower.queue.map((t) => t.id), ['a', 'b']);
      expect(audio.schedules, 1);
      send('stop', {'taskId': 'new-task'});
      await eventually(() => follower.phase == SessionPhase.standby);
      send('reset_task', {
        'taskId': 'old-task',
        'track': trackA.toWire(),
        ...snapshot(1, 0),
      });
      send('notice', {'reason': 'stopped-marker'});
      await eventually(() => follower.message == 'stopped-marker');
      expect(follower.queue, isEmpty);
      expect(follower.taskId, isNull);
    },
  );

  test(
    'focus suppression preserves both sessions and current user output',
    () async {
      final masterAudio = FakeAudio();
      final followerAudio = FakeAudio();
      var masterFocusRequests = 0;
      var followerFocusRequests = 0;
      final master = await device(
        'master',
        audio: masterAudio,
        acquireAudioFocus: () async {
          masterFocusRequests++;
          return true;
        },
      );
      final follower = await device(
        'follower',
        audio: followerAudio,
        acquireAudioFocus: () async {
          followerFocusRequests++;
          return true;
        },
      );
      await master.createRoom();
      await connect(master, follower);
      master.setOutput(volume: 0.8);
      follower.setOutput(volume: 0.6, channel: AudioChannel.left);
      await master.play(trackA);
      await eventually(() => followerAudio.schedules == 1);
      final session = master.sessionId;
      final task = master.taskId;
      final masterStops = masterAudio.stops;
      final followerStops = followerAudio.stops;
      var focusNotifications = 0;
      void listener() {
        focusNotifications++;
      }

      master.addListener(listener);
      master.setFocusAttenuation(0.2);
      expect(masterAudio.volume, closeTo(0.16, 0.0001));
      expect(master.localDevice.volume, 0.8);
      expect(master.localDevice.muted, isFalse);
      expect(focusNotifications, 1);
      master.removeListener(listener);
      follower.setFocusAttenuation(0);
      expect(followerAudio.volume, 0);
      expect(follower.localDevice.volume, 0.6);
      expect(follower.localDevice.muted, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(master.members.firstWhere((d) => d.id == 'follower').volume, 0.6);
      expect(master.sessionId, session);
      expect(follower.sessionId, session);
      expect(master.taskId, task);
      expect(follower.taskId, task);
      expect(master.members.length, 2);
      expect(masterAudio.stops, masterStops);
      expect(followerAudio.stops, followerStops);
      expect(masterAudio.schedules, 1);
      expect(followerAudio.schedules, 1);
      expect(master.masterSelectionRequired, isFalse);

      // User edits and remote output updates retain the temporary local mask.
      master.setOutput(volume: 0.4, muted: true);
      master.setOutput(deviceId: 'follower', volume: 0.3);
      await eventually(() => follower.localDevice.volume == 0.3);
      expect(followerAudio.volume, 0);
      master.setFocusAttenuation(1);
      expect(masterAudio.volume, 0.4);
      expect(masterAudio.muted, isTrue);
      master.setOutput(muted: false);
      expect(masterAudio.volume, 0.4);
      expect(masterAudio.muted, isFalse);

      // Switching tracks while another app owns focus must not request it again.
      await master.play(trackB);
      await eventually(() => followerAudio.schedules == 2);
      expect(masterFocusRequests, 1);
      expect(followerFocusRequests, 1);
      expect(followerAudio.volume, 0);
      follower.setFocusAttenuation(1);
      expect(followerAudio.volume, 0.3);
      expect(followerAudio.channel, AudioChannel.left);
      expect(followerAudio.muted, isFalse);
      follower.setOutput(volume: 0);
      follower.setFocusAttenuation(0);
      follower.setFocusAttenuation(1);
      expect(followerAudio.volume, 0);

      master.setFocusAttenuation(0);
      await master.endPlayback();
      await eventually(() => follower.phase == SessionPhase.standby);
      master.setFocusAttenuation(0.2); // Late callbacks while idle are ignored.
      await master.play(trackA);
      await eventually(() => followerAudio.schedules == 3);
      expect(masterAudio.volume, 0.4);
      expect(masterFocusRequests, 2);
      expect(followerFocusRequests, 2);
    },
  );

  test(
    'media lifetime starts before focus and rolls back a denied request',
    () async {
      final calls = <String>[];
      final audio = FakeAudio();
      final master = await device(
        'master',
        audio: audio,
        setPlaybackActive: (active) async {
          calls.add('active:$active');
        },
        acquireAudioFocus: () async {
          calls.add('focus');
          return false;
        },
        releaseAudioFocus: () async {
          calls.add('release');
        },
      );
      await master.createRoom();
      calls.clear();
      await master.play(trackA);
      expect(calls.take(4), [
        'active:true',
        'focus',
        'release',
        'active:false',
      ]);
      expect(audio.schedules, 0);
      expect(master.phase, SessionPhase.standby);
      expect(master.masterSelectionRequired, isTrue);
      expect(calls.last, 'active:false');
    },
  );

  test(
    'explicit focus recovery preserves playback and current user settings',
    () async {
      var response = Completer<bool>();
      var requests = 0;
      final audio = FakeAudio();
      final master = await device(
        'master',
        audio: audio,
        resumeAudioFocus: () {
          requests++;
          return response.future;
        },
      );
      await master.createRoom();
      await master.restoreLocalAudioFocus();
      expect(requests, 0);
      await master.play(trackA);
      await master.restoreLocalAudioFocus();
      expect(requests, 0);
      master.setFocusAttenuation(0);
      final task = master.taskId;
      final stops = audio.stops;
      final recovering = master.restoreLocalAudioFocus();
      final repeated = master.restoreLocalAudioFocus();
      expect(requests, 1);
      master.setOutput(volume: 0.55, muted: true);
      response.complete(false);
      await Future.wait([recovering, repeated]);
      expect(master.focusAttenuation, 0);
      expect(master.message, contains('暂时无法恢复本机声音'));
      expect(master.masterSelectionRequired, isFalse);
      response = Completer<bool>();
      final successful = master.restoreLocalAudioFocus();
      response.complete(true);
      await successful;
      expect(master.focusAttenuation, 1);
      expect(master.message, isNull);
      expect(audio.volume, 0.55);
      expect(audio.muted, isTrue);
      expect(master.taskId, task);
      expect(audio.stops, stops);
      expect(audio.schedules, 1);
      expect(master.phase, SessionPhase.scheduled);

      // A new loss after the user's request wins over its delayed success.
      response = Completer<bool>();
      master.setFocusAttenuation(0);
      final superseded = master.restoreLocalAudioFocus();
      master.setFocusAttenuation(0);
      response.complete(true);
      await superseded;
      expect(master.focusAttenuation, 0);

      // A result from an ended playback cannot unmute the next playback.
      response = Completer<bool>();
      final late = master.restoreLocalAudioFocus();
      await master.endPlayback();
      await master.play(trackB);
      master.setFocusAttenuation(0.2);
      response.complete(true);
      await late;
      expect(master.focusAttenuation, 0.2);
      expect(master.taskId, isNot(task));
      expect(audio.volume, closeTo(0.11, 0.0001));
      expect(audio.muted, isTrue);
    },
  );

  test(
    'a platform recovery exception only leaves local output muted',
    () async {
      final audio = FakeAudio();
      final master = await device(
        'master',
        audio: audio,
        resumeAudioFocus: () async => throw StateError('focus unavailable'),
      );
      await master.createRoom();
      await master.play(trackA);
      final task = master.taskId;
      master.setFocusAttenuation(0);
      await master.restoreLocalAudioFocus();
      expect(master.focusAttenuation, 0);
      expect(master.taskId, task);
      expect(master.phase, SessionPhase.scheduled);
      expect(master.masterSelectionRequired, isFalse);
      expect(master.message, contains('暂时无法恢复本机声音'));
    },
  );

  for (final leaveRoom in [false, true]) {
    test(
      '${leaveRoom ? 'leaving' : 'ending'} with a delayed stop cannot release a newer playback session',
      () async {
        final audio = FakeAudio();
        final activeCalls = <bool>[];
        var focusRequests = 0;
        Completer<void>? nextReleaseGate;
        final master = await device(
          'master',
          audio: audio,
          setPlaybackActive: (active) async {
            activeCalls.add(active);
          },
          acquireAudioFocus: () async {
            focusRequests++;
            return true;
          },
          releaseAudioFocus: () async {
            final gate = nextReleaseGate;
            nextReleaseGate = null;
            if (gate != null) await gate.future;
          },
        );
        await master.createRoom();
        await master.play(trackA);
        final previousTask = master.taskId;
        final stopGate = Completer<void>();
        final releaseGate = Completer<void>();
        audio.stopGate = stopGate;
        nextReleaseGate = releaseGate;
        final oldStop = leaveRoom ? master.leave() : master.endPlayback();

        // The UI can select a new resource while the prior stop is completing.
        // Its lease must be new even if neither old async operation has ended.
        if (leaveRoom) await master.createRoom();
        await master.play(trackB);
        master.setFocusAttenuation(0.2);
        final newTask = master.taskId;
        final activeCount = activeCalls.length;
        expect(newTask, isNot(previousTask));
        expect(focusRequests, 2);
        expect(activeCalls.last, isTrue);
        stopGate.complete();
        releaseGate.complete();
        await oldStop;
        expect(activeCalls.length, activeCount);
        expect(activeCalls.last, isTrue);
        expect(master.taskId, newTask);
        expect(master.phase, SessionPhase.scheduled);
        expect(master.focusAttenuation, 0.2);
        expect(audio.volume, 0.2);
        expect(master.masterSelectionRequired, isFalse);
      },
    );
  }

  test('ending during service activation never requests late focus', () async {
    final activation = Completer<void>();
    final entered = Completer<void>();
    final calls = <String>[];
    final audio = FakeAudio();
    final master = await device(
      'master',
      audio: audio,
      setPlaybackActive: (active) async {
        calls.add('active:$active');
        if (active) {
          entered.complete();
          await activation.future;
        }
      },
      acquireAudioFocus: () async {
        calls.add('focus');
        return true;
      },
      releaseAudioFocus: () async {
        calls.add('release');
      },
    );
    await master.createRoom();
    calls.clear();
    final playing = master.play(trackA);
    await entered.future;
    await master.endPlayback();
    activation.complete();
    await playing;
    expect(calls, ['active:true', 'release', 'active:false']);
    expect(audio.schedules, 0);
    expect(master.phase, SessionPhase.standby);
    expect(master.masterSelectionRequired, isFalse);
  });

  test(
    'joining requires master approval; group capacity includes master',
    () async {
      final master = await device('master');
      await master.createRoom();
      final first = await device('follower0');
      await first.join('127.0.0.1', port: master.serverPort);
      await eventually(() => master.pendingJoins.length == 1);
      expect(first.isConnected, isFalse);
      expect(first.isJoining, isTrue);
      master.approveJoin(first.localDevice.id);
      await eventually(() => first.isConnected);
      for (var i = 1; i < 5; i++) {
        await connect(master, await device('follower$i'));
      }
      expect(master.members.length, 6);
      final seventh = await device('seventh');
      await seventh.join('127.0.0.1', port: master.serverPort);
      await eventually(() => !seventh.isJoining);
      expect(seventh.isConnected, isFalse);
      expect(master.members.length, 6);
    },
  );

  test(
    'all real participant READY messages are required and membership stays locked through track change',
    () async {
      final masterAudio = FakeAudio();
      final followerAudio = FakeAudio()..gate = Completer<void>();
      final master = await device('master', audio: masterAudio);
      final follower = await device('follower', audio: followerAudio);
      await master.createRoom();
      await connect(master, follower);
      await master.play(trackA);
      await eventually(() => followerAudio.preparedTask != null);
      expect(master.phase, SessionPhase.preparing);
      expect(masterAudio.schedules, 0);
      final late = await device('late');
      await late.join('127.0.0.1', port: master.serverPort);
      await eventually(() => !late.isJoining);
      expect(late.isConnected, isFalse);
      followerAudio.gate!.complete();
      await eventually(
        () => masterAudio.schedules == 1 && followerAudio.schedules == 1,
      );
      expect(master.phase, SessionPhase.scheduled);
      final previous = master.taskId;
      final stopCount = masterAudio.stops;
      await master.restartDiscovery();
      expect(master.taskId, previous);
      expect(master.phase, SessionPhase.scheduled);
      expect(masterAudio.stops, stopCount);
      expect(master.members.length, 2);
      await master.play(trackB);
      await eventually(
        () => masterAudio.schedules == 2 && followerAudio.schedules == 2,
      );
      expect(master.taskId, isNot(previous));
      expect(master.membersLocked, isTrue);
      await master.endPlayback();
      await eventually(() => follower.phase == SessionPhase.standby);
      expect(master.membersLocked, isFalse);
      await connect(master, late);
      expect(master.members.length, 3);
    },
  );

  test(
    'stale READY from an old task or session never schedules a new task',
    () async {
      final audio = FakeAudio();
      final master = await device('master', audio: audio);
      await master.createRoom();
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${master.serverPort}/heming',
      );
      final sub = socket.listen((dynamic value) {
        final message = jsonDecode(value as String) as Map;
        if (message['type'] == 'ping') {
          socket.add(jsonEncode({'v': 1, 'type': 'pong'}));
        }
      });
      addTearDown(() async {
        await sub.cancel();
        await socket.close();
      });
      socket.add(
        jsonEncode({
          'v': 1,
          'type': 'join',
          'device': const DeviceMember(
            id: 'raw',
            name: 'raw',
            platform: 'test',
            address: '127.0.0.1',
            port: 12345,
          ).toJson(),
        }),
      );
      await eventually(() => master.pendingJoins.isNotEmpty);
      master.approveJoin('raw');
      await master.play(trackA);
      final oldTask = master.taskId;
      await master.play(trackB);
      void ready(String session, String task) => socket.add(
        jsonEncode({
          'v': 1,
          'type': 'ready',
          'sessionId': session,
          'taskId': task,
        }),
      );
      ready(master.sessionId!, oldTask!);
      ready('old-session', master.taskId!);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(audio.schedules, 0);
      ready(master.sessionId!, master.taskId!);
      await eventually(() => audio.schedules == 1);
    },
  );

  test(
    'playlist snapshots skip ineligible entries and recheck files before advancing',
    () async {
      var bExists = true;
      final audio = FakeAudio();
      final master = await device(
        'master',
        audio: audio,
        validator: (track) async => track.id != 'b' || bExists,
      );
      await master.createRoom();
      await master.startPlaylist([trackA, unplayable, trackB]);
      expect(master.queue.map((t) => t.id), ['a', 'b']);
      expect(master.skippedCount, 1);
      expect(master.currentTrack?.id, 'a');
      final activeTask = master.taskId;
      await master.play(unplayable);
      expect(master.taskId, activeTask);
      bExists = false;
      audio.emit(PlaybackAudioState.playing);
      audio.emit(PlaybackAudioState.completed);
      await eventually(() => master.phase == SessionPhase.standby);
      expect(master.skippedCount, 2);
      expect(audio.schedules, 1);
    },
  );

  test(
    'authorized handover preserves members and output settings but clears all playback',
    () async {
      final old = await device('old');
      final next = await device('next');
      final third = await device('third');
      await old.createRoom();
      await connect(old, next);
      await connect(old, third);
      old.setOutput(
        deviceId: 'third',
        channel: AudioChannel.left,
        volume: 0.35,
        muted: true,
      );
      await eventually(() => third.localDevice.muted);
      await old.play(trackA);
      await eventually(
        () =>
            next.phase == SessionPhase.scheduled &&
            third.phase == SessionPhase.scheduled,
        reason: 'initial 3-device schedule',
      );
      final oldSession = old.sessionId;
      next.requestTakeover();
      await eventually(() => old.takeoverRequester == 'next');
      await old.approveTakeover();
      await eventually(
        () =>
            next.isMaster && old.masterId == 'next' && third.masterId == 'next',
        reason: 'all devices recognize new master',
      );
      await eventually(
        () => next.members.length == 3 && old.isConnected && third.isConnected,
        reason: 'all devices reconnect',
      );
      expect(next.sessionId, isNot(oldSession));
      for (final controller in [old, next, third]) {
        expect(controller.phase, SessionPhase.standby);
        expect(controller.currentTrack, isNull);
        expect(controller.taskId, isNull);
      }
      expect(third.localDevice.channel, AudioChannel.left);
      expect(third.localDevice.volume, 0.35);
      expect(third.localDevice.muted, isTrue);
      await next.play(trackB);
      await eventually(
        () =>
            next.phase == SessionPhase.scheduled &&
            old.phase == SessionPhase.scheduled &&
            third.phase == SessionPhase.scheduled,
        reason: 'new master schedules new resource',
      );
    },
  );

  test(
    'handover retries a connected target that has not processed promotion yet',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final sourceConnection = Completer<WebSocket>();
      final follower = await device('migrating');
      final devices = [
        DeviceMember(
          id: 'source',
          name: 'source',
          platform: 'test',
          address: '127.0.0.1',
          port: source.port,
        ),
        DeviceMember(
          id: 'target',
          name: 'target',
          platform: 'test',
          address: '127.0.0.1',
          port: target.port,
        ),
        follower.localDevice,
      ].map((d) => d.toJson()).toList();
      var attempts = 0;
      source.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        sourceConnection.complete(socket);
        socket.listen((dynamic value) {
          final message = jsonDecode(value as String) as Map;
          if (message['type'] == 'join') {
            socket.add(
              jsonEncode({
                'v': 1,
                'type': 'welcome',
                'sessionId': 'old',
                'masterId': 'source',
                'members': devices,
              }),
            );
          }
        });
      });
      target.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((dynamic value) {
          final message = jsonDecode(value as String) as Map;
          if (message['type'] == 'rejoin') {
            attempts++;
            expect(message['token'], 'authorized-token');
            if (attempts == 1) {
              socket.add(
                jsonEncode({'v': 1, 'type': 'rejected', 'reason': '此设备当前不是主控'}),
              );
              unawaited(socket.close());
            } else {
              socket.add(
                jsonEncode({
                  'v': 1,
                  'type': 'welcome',
                  'sessionId': 'new',
                  'masterId': 'target',
                  'members': devices,
                }),
              );
            }
          } else if (message['type'] == 'ping') {
            socket.add(jsonEncode({'v': 1, 'type': 'pong'}));
          }
        });
      });
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await target.close(force: true);
        await source.close(force: true);
      });
      await follower.join('127.0.0.1', port: source.port);
      await eventually(() => follower.isConnected);
      (await sourceConnection.future).add(
        jsonEncode({
          'v': 1,
          'type': 'handover',
          'sessionId': 'old',
          'newSessionId': 'new',
          'masterId': 'target',
          'token': 'authorized-token',
          'members': devices,
        }),
      );
      await eventually(
        () =>
            attempts == 2 &&
            follower.sessionId == 'new' &&
            follower.masterId == 'target' &&
            follower.message == '已连接，等待主控选择资源',
      );
      expect(follower.phase, SessionPhase.standby);
      expect(follower.error, isNull);
    },
  );

  test('cancelled join cannot replace or fail a newer pending join', () async {
    for (final lateSuccess in [true, false]) {
      final master = await device('current-$lateSuccess');
      final follower = await device('joining-$lateSuccess');
      await master.createRoom();
      final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final request = Completer<HttpRequest>();
      slow.listen((incoming) => request.complete(incoming));
      WebSocket? staleSocket;
      addTearDown(() async {
        await staleSocket?.close();
        await slow.close(force: true);
      });
      final obsolete = follower.join('127.0.0.1', port: slow.port);
      final incoming = await request.future;
      await follower.leave();
      await follower.join('127.0.0.1', port: master.serverPort);
      await eventually(() => master.pendingJoins.isNotEmpty);
      var staleJoinSent = false;
      if (lateSuccess) {
        staleSocket = await WebSocketTransformer.upgrade(incoming);
        staleSocket.listen((dynamic value) {
          if ((jsonDecode(value as String) as Map)['type'] == 'join') {
            staleJoinSent = true;
          }
        });
      } else {
        incoming.response.statusCode = HttpStatus.serviceUnavailable;
        await incoming.response.close();
      }
      await obsolete;
      expect(follower.isJoining, isTrue);
      expect(follower.error, isNull);
      expect(staleJoinSent, isFalse);
      master.approveJoin(follower.localDevice.id);
      await eventually(() => follower.masterId == master.localDevice.id);
    }
  });

  test(
    'a superseded handover cannot install its timer into a newly created room',
    () async {
      final nextAudio = FakeAudio();
      final old = await device('old-cancel');
      final next = await device(
        'next-cancel',
        audio: nextAudio,
        heartbeatTimeout: const Duration(milliseconds: 250),
      );
      await old.createRoom();
      await connect(old, next);
      next.requestTakeover();
      await eventually(() => old.takeoverRequester != null);
      final stop = Completer<void>();
      nextAudio.stopGate = stop;
      final transferring = old.approveTakeover();
      await eventually(() => next.isMaster && nextAudio.stopGate == null);
      final obsoleteSession = next.sessionId;
      await next.createRoom();
      final replacementSession = next.sessionId;
      expect(replacementSession, isNot(obsoleteSession));
      stop.complete();
      await transferring;
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(next.sessionId, replacementSession);
      expect(next.isMaster, isTrue);
      expect(next.members.map((d) => d.id), [next.localDevice.id]);
      expect(next.handoverInProgress, isFalse);
      await next.play(trackA);
      expect(next.phase, SessionPhase.scheduled);
    },
  );

  test(
    'slave interruption exits alone; master interruption stops every member',
    () async {
      final master = await device('master');
      final first = await device('first');
      final second = await device('second');
      await master.createRoom();
      await connect(master, first);
      await connect(master, second);
      await master.play(trackA);
      await eventually(() => second.phase == SessionPhase.scheduled);
      await first.handleInterruption('屏幕锁定');
      await eventually(() => master.members.length == 2);
      expect(first.isConnected, isFalse);
      expect(master.membersLocked, isTrue);
      await master.handleInterruption('输出设备变化');
      await eventually(() => second.phase == SessionPhase.standby);
      expect(master.phase, SessionPhase.standby);
      expect(master.members.length, 2);
      expect(master.masterSelectionRequired, isTrue);
      expect(second.masterSelectionRequired, isTrue);
      await master.play(trackB);
      expect(master.taskId, isNull);
      expect(master.canSelectResources, isFalse);
      // New members also receive the selection requirement in WELCOME.
      await connect(master, first);
      expect(first.masterSelectionRequired, isTrue);
      master.confirmMasterSelection();
      await eventually(
        () => !second.masterSelectionRequired && !first.masterSelectionRequired,
      );
      expect(master.canSelectResources, isTrue);
      await master.play(trackB);
      await eventually(() => second.phase == SessionPhase.scheduled);
      // Selecting a different master is also an explicit valid recovery.
      await master.handleInterruption('音频焦点丢失');
      second.requestTakeover();
      await eventually(() => master.takeoverRequester == 'second');
      await master.approveTakeover();
      await eventually(() => second.isMaster && !second.handoverInProgress);
      expect(second.masterSelectionRequired, isFalse);
      await second.play(trackA);
      await eventually(() => master.phase == SessionPhase.scheduled);
    },
  );

  test(
    'native output failures stop playback and cannot silently retain playback authority',
    () async {
      final masterAudio = FakeAudio();
      final firstAudio = FakeAudio();
      final master = await device('master', audio: masterAudio);
      final first = await device('first', audio: firstAudio);
      final second = await device('second');
      await master.handleInterruption('未组队的输出变化');
      expect(master.message, isNull);
      await master.createRoom();
      await connect(master, first);
      await connect(master, second);
      await master.play(trackA);
      await eventually(
        () =>
            first.phase == SessionPhase.scheduled &&
            second.phase == SessionPhase.scheduled,
      );
      firstAudio.emit(PlaybackAudioState.failed, error: '播放缓冲耗尽');
      await eventually(() => !first.isConnected && master.members.length == 2);
      expect(master.membersLocked, isTrue);
      masterAudio.emit(PlaybackAudioState.failed, error: '音频输出设备已丢失');
      await eventually(() => second.phase == SessionPhase.standby);
      expect(master.masterSelectionRequired, isTrue);
      expect(second.masterSelectionRequired, isTrue);
      expect(master.taskId, isNull);
      expect(master.queue, isEmpty);
      await master.play(trackB);
      expect(master.taskId, isNull);
      expect(masterAudio.schedules, 1);
      // Initialization may throw before the periodic native status poll emits
      // FAILED. This route must enforce the same stopped/selection state.
      master.confirmMasterSelection();
      masterAudio.preparationError = StateError('没有可用音频输出');
      await master.play(trackB);
      await eventually(() => second.phase == SessionPhase.standby);
      expect(master.masterSelectionRequired, isTrue);
      expect(second.masterSelectionRequired, isTrue);
      expect(master.taskId, isNull);
      expect(masterAudio.schedules, 1);
    },
  );

  test(
    'preparation timeout clears task; delayed preparation cannot restart it',
    () async {
      final audio = FakeAudio()..gate = Completer<void>();
      final master = await device(
        'master',
        audio: audio,
        prepareTimeout: const Duration(milliseconds: 100),
      );
      await master.createRoom();
      final preparing = master.play(trackA);
      await eventually(() => master.phase == SessionPhase.preparing);
      await eventually(() => master.phase == SessionPhase.standby);
      audio.gate!.complete();
      await preparing;
      expect(master.taskId, isNull);
      expect(audio.schedules, 0);
      expect(master.message, contains('准备超时'));
    },
  );

  test(
    'a silent control peer expires even when it keeps its TCP socket open',
    () async {
      final master = await device(
        'master',
        heartbeatTimeout: const Duration(milliseconds: 250),
      );
      await master.createRoom();
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${master.serverPort}/heming',
      );
      final sub = socket.listen((_) {});
      addTearDown(() async {
        await sub.cancel();
        await socket.close();
      });
      socket.add(
        jsonEncode({
          'v': 1,
          'type': 'join',
          'device': const DeviceMember(
            id: 'silent',
            name: 'silent',
            platform: 'test',
            address: '127.0.0.1',
            port: 12345,
          ).toJson(),
        }),
      );
      await eventually(() => master.pendingJoins.isNotEmpty);
      master.approveJoin('silent');
      expect(master.members.length, 2);
      await eventually(() => master.members.length == 1);
    },
  );
}
