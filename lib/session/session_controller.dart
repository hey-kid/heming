import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../networking/control_transport.dart';
import '../networking/mdns_discovery.dart';
import '../shared/models.dart';
import 'audio_session_port.dart';

export '../shared/models.dart';
export 'audio_session_port.dart';

String _newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// The only authority for group membership and playback state.
/// Wall time is used only for UI labels. Native monotonic time schedules audio.
class SessionController extends ChangeNotifier {
  static const _focusRecoveryFailure = '暂时无法恢复本机声音，请在其他音频结束后重试';
  SessionController({
    required this.audio,
    required String deviceId,
    required String deviceName,
    String platformName = 'unknown',
    this.acquireAudioFocus,
    this.resumeAudioFocus,
    this.releaseAudioFocus,
    this.setPlaybackActive,
    this.heartbeatInterval = const Duration(seconds: 2),
    this.heartbeatTimeout = const Duration(seconds: 7),
    this.prepareTimeout = const Duration(seconds: 25),
    this.startLead = const Duration(milliseconds: 1500),
    this.enableDiscovery = true,
    Future<bool> Function(PlayableTrack)? validateTrack,
  }) : _localDevice = DeviceMember(
         id: deviceId,
         name: deviceName,
         platform: platformName,
         address: '',
         port: 0,
       ),
       _validateTrack = validateTrack ?? _readableTrack;

  final AudioSessionPort audio;
  final Future<bool> Function()? acquireAudioFocus;
  final Future<bool> Function()? resumeAudioFocus;
  final Future<void> Function()? releaseAudioFocus;
  final Future<void> Function(bool)? setPlaybackActive;
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;
  final Duration prepareTimeout;
  final Duration startLead;
  final bool enableDiscovery;
  final Future<bool> Function(PlayableTrack) _validateTrack;
  final ControlServer _server = ControlServer();
  MdnsDiscovery? _discovery;
  final Map<String, DeviceMember> _members = {};
  final Map<String, ControlConnection> _peers = {};
  final Map<String, JoinRequest> _pendingJoins = {};
  final Set<ControlConnection> _connections = {};
  final Set<String> _participants = {};
  final Set<String> _readyDeviceIds = {};
  final Set<String> _expectedRejoins = {};
  DeviceMember _localDevice;
  ControlConnection? _masterConnection;
  StreamSubscription<PlaybackAudioStatus>? _audioSubscription;
  Timer? _heartbeatTimer;
  Timer? _prepareTimer;
  Timer? _displayStartTimer;
  Timer? _handoverExpiry;
  SessionPhase _phase = SessionPhase.disconnected;
  String? _sessionId;
  String? _masterId;
  String? _taskId;
  String? _handoverToken;
  Completer<void>? _handoverReady;
  Completer<bool>? _migrationAcceptance;
  String? _takeoverRequester;
  bool _disposed = false;
  bool _notifierDisposed = false;
  bool _initialized = false;
  bool _joining = false;
  bool _masterSelectionRequired = false;
  bool _focusSessionActive = false;
  Future<bool>? _focusAcquisition;
  Future<void>? _focusRestoration;
  int _focusGeneration = 0;
  int _focusChangeRevision = 0;
  double _focusAttenuation = 1;
  int _playRequest = 0;
  int _connectionAttempt = 0;
  int _queueIndex = -1;
  int _skippedCount = 0;
  int _queueRevision = 0;
  int _receivedQueueRevision = -1;
  PlaybackMode _playbackMode = PlaybackMode.sequential;
  PlaybackMode _activePlaybackMode = PlaybackMode.sequential;
  final Random _queueRandom = Random();
  final Set<int> _visitedQueueIndices = {};
  final List<int> _playHistory = [];
  int _historyIndex = -1;
  List<PlayableTrack> _queue = [];
  PlayableTrack? _currentTrack;
  String? _message;
  String? _error;
  List<String> _localAddresses = [];
  PlaybackAudioStatus _audioStatus = const PlaybackAudioStatus(
    state: PlaybackAudioState.idle,
  );

  SessionPhase get phase => _phase;
  bool get isMaster => _masterId == _localDevice.id && _sessionId != null;
  bool get isConnected => _sessionId != null;
  bool get isJoining => _joining;
  bool get masterSelectionRequired => _masterSelectionRequired;
  bool get canSelectResources => isMaster && !_masterSelectionRequired;
  bool get handoverInProgress => _expectedRejoins.isNotEmpty;
  bool get membersLocked =>
      _phase == SessionPhase.preparing ||
      _phase == SessionPhase.scheduled ||
      _phase == SessionPhase.playing;
  DeviceMember get localDevice => _localDevice;
  String? get sessionId => _sessionId;
  String? get taskId => _taskId;
  String? get masterId => _masterId;
  List<DeviceMember> get members => List.unmodifiable(_members.values);
  List<JoinRequest> get pendingJoins => List.unmodifiable(_pendingJoins.values);
  Set<String> get readyDeviceIds => Set.unmodifiable(_readyDeviceIds);
  String? get takeoverRequester => _takeoverRequester;
  List<PlayableTrack> get queue => List.unmodifiable(_queue);
  int get queueIndex => _queueIndex;
  int get skippedCount => _skippedCount;
  PlaybackMode get playbackMode => _playbackMode;
  bool get modeChangePending =>
      _currentTrack != null && _playbackMode != _activePlaybackMode;
  bool get canPreviousTrack =>
      canSelectResources &&
      _currentTrack != null &&
      (_activePlaybackMode == PlaybackMode.sequential
          ? _queueIndex > 0
          : _historyIndex > 0);
  bool get canNextTrack =>
      canSelectResources && _currentTrack != null && _hasNextTrack;
  bool get _hasNextTrack {
    if (!modeChangePending && _historyIndex + 1 < _playHistory.length) {
      return true;
    }
    return _playbackMode == PlaybackMode.random
        ? _visitedQueueIndices.length < _queue.length
        : _queueIndex + 1 < _queue.length;
  }

  PlayableTrack? get currentTrack => _currentTrack;
  String? get message => _message;
  String? get error => _error;
  int get serverPort => _server.port;
  List<String> get localAddresses => List.unmodifiable(_localAddresses);
  List<DiscoveredRoom> get discoveredRooms => _discovery?.rooms ?? const [];
  bool get discoveryAvailable => _discovery?.available ?? false;
  double get focusAttenuation => _focusAttenuation;
  Future<void> refreshDiscovery() async => _discovery?.refresh();
  Future<void> restartDiscovery() async {
    if (_disposed) return;
    await _discovery?.restart();
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      if (_disposed) return;
      _updateLocalAddresses(interfaces);
      if (_members.containsKey(_localDevice.id)) {
        _members[_localDevice.id] = _localDevice;
      }
      if (isMaster) _broadcastMembers();
      _changed();
    } on SocketException {
      /* Keep the last usable display address if enumeration fails. */
    }
  }

  double get bufferSeconds => _audioStatus.bufferedFrames / 48000;
  int get positionMs => _audioStatus.playedFrames * 1000 ~/ 48000;
  int get clockRttMicros => _audioStatus.clockRttMicros;
  int get clockOffsetMicros => _audioStatus.clockOffsetMicros;

  static Future<bool> _readableTrack(PlayableTrack track) async {
    if (!track.isPlayable || track.path.isEmpty) return false;
    RandomAccessFile? file;
    try {
      file = await File(track.path).open();
      return await file.length() > 0;
    } on FileSystemException {
      return false;
    } finally {
      await file?.close();
    }
  }

  Future<void> initialize({int port = 19786}) async {
    if (_initialized) return;
    try {
      await _server.start(port: port, onConnection: _acceptConnection);
    } on SocketException {
      if (port == 0) rethrow;
      // Another local app instance may already use the default port.
      await _server.start(port: 0, onConnection: _acceptConnection);
    }
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    _updateLocalAddresses(interfaces);
    _audioSubscription = audio.statuses.listen(
      _onAudioStatus,
      onError: (Object error) => unawaited(handleInterruption('音频引擎异常：$error')),
    );
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _heartbeat());
    _initialized = true;
    if (enableDiscovery) {
      _discovery = MdnsDiscovery(
        deviceId: _localDevice.id,
        onChanged: _changed,
      );
      await _discovery!.start();
    }
    _changed();
  }

  void _updateLocalAddresses(List<NetworkInterface> interfaces) {
    int priority(NetworkInterface interface) {
      final name = interface.name.toLowerCase();
      if (RegExp(
        r'vmware|vmnet|vethernet|virtual|meta|tun|tap|vpn|wsl|docker|loopback',
      ).hasMatch(name)) {
        return 2;
      }
      if (RegExp(r'wi-?fi|wlan|wireless|ethernet|以太网|无线').hasMatch(name)) {
        return 0;
      }
      return 1;
    }

    interfaces.sort((a, b) => priority(a).compareTo(priority(b)));
    _localAddresses = interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .map((a) => a.address)
        .toList();
    _localDevice = _localDevice.copyWith(
      port: _server.port,
      address: _localAddresses.isEmpty ? '127.0.0.1' : _localAddresses.first,
    );
  }

  Future<void> createRoom() async {
    final attempt = ++_connectionAttempt;
    await initialize();
    if (attempt != _connectionAttempt || _disposed) return;
    await _leave(invalidateConnectionAttempt: false);
    if (attempt != _connectionAttempt || _disposed) return;
    _sessionId = _newId();
    _masterId = _localDevice.id;
    _members[_localDevice.id] = _localDevice;
    _phase = SessionPhase.standby;
    _error = null;
    _message = '播放组已创建，等待其他设备加入';
    _changed();
  }

  Future<void> join(String host, {int port = 19786}) async {
    if (host.trim().isEmpty || port < 1 || port > 65535) {
      _fail('请输入有效的主控地址和端口');
      return;
    }
    final attempt = ++_connectionAttempt;
    await initialize();
    if (attempt != _connectionAttempt || _disposed) return;
    await _leave(invalidateConnectionAttempt: false);
    if (attempt != _connectionAttempt || _disposed) return;
    _joining = true;
    _error = null;
    _message = '正在连接主控…';
    _changed();
    try {
      final connection = await ControlServer.connect(host.trim(), port);
      if (attempt != _connectionAttempt || !_joining || _disposed) {
        await connection.dispose();
        return;
      }
      _attachMaster(connection);
      connection.send('join', {'device': _localDevice.toJson()});
      _message = '已发送加入申请，请等待主控接受';
      _changed();
    } catch (error) {
      if (attempt != _connectionAttempt || _disposed) return;
      _joining = false;
      _fail('无法连接主控，请检查同一局域网、地址和防火墙：$error');
    }
  }

  void _attachMaster(ControlConnection connection) {
    _masterConnection = connection;
    _connections.add(connection);
    connection.listen((message) => _onMasterMessage(connection, message), () {
      _connections.remove(connection);
      if (_masterConnection == connection && !_disposed) {
        _masterConnection = null;
        final migration = _migrationAcceptance;
        if (migration != null && !migration.isCompleted) {
          migration.complete(false);
        } else {
          unawaited(_lostMaster('主控连接已断开，播放已停止，请重新建组'));
        }
      }
    });
  }

  void _acceptConnection(ControlConnection connection) {
    if (_disposed) {
      unawaited(connection.dispose());
      return;
    }
    _connections.add(connection);
    connection.listen((message) => _onPeerMessage(connection, message), () {
      _connections.remove(connection);
      final id = connection.deviceId;
      if (id != null && _peers[id] == connection) {
        _peers.remove(id);
        _pendingJoins.remove(id);
        if (isMaster && _members.containsKey(id)) {
          _removeMember(id, '设备已退出，其他设备继续播放；请检查声道分配');
        }
        _changed();
      }
    });
  }

  void approveJoin(String id) {
    if (!isMaster) return;
    final request = _pendingJoins[id];
    final connection = _peers[id];
    if (request == null || connection == null) return;
    if (membersLocked || _members.length >= 6) {
      rejectJoin(
        id,
        reason: membersLocked ? '播放期间禁止加入，请等待待命状态' : '播放组已满（最多六台）',
      );
      return;
    }
    _pendingJoins.remove(id);
    connection.accepted = true;
    _members[id] = request.device;
    connection.send('welcome', _snapshot());
    _broadcastMembers();
    _message = '${request.name} 已加入';
    _changed();
  }

  void rejectJoin(String id, {String reason = '主控拒绝了加入申请'}) {
    if (!isMaster) return;
    final connection = _peers.remove(id);
    _pendingJoins.remove(id);
    connection?.send('rejected', {'reason': reason});
    if (connection != null) unawaited(connection.close());
    _changed();
  }

  void removeMember(String id) {
    if (!isMaster || id == _localDevice.id) return;
    final connection = _peers.remove(id);
    connection?.send('removed', {
      'sessionId': _sessionId,
      'reason': '主控已将本机移出播放组',
    });
    if (connection != null) unawaited(connection.close());
    _removeMember(id, '设备已移出，请检查声道分配');
  }

  void _removeMember(String id, String reason) {
    _members.remove(id);
    _participants.remove(id);
    _readyDeviceIds.remove(id);
    if (_takeoverRequester == id) _takeoverRequester = null;
    _message = reason;
    _broadcastMembers();
    _maybeSchedule();
    _changed();
  }

  Future<void> play(PlayableTrack track) => startPlaylist([track]);

  Future<void> startPlaylist(
    List<PlayableTrack> tracks, {
    int startIndex = 0,
  }) async {
    if (isConnected && !isMaster) {
      _fail('只有主控可以选择资源');
      return;
    }
    if (_masterSelectionRequired) {
      _fail('主控已中断，请先在设备页重新选择主控');
      return;
    }
    if (tracks.isNotEmpty) {
      RangeError.checkValidIndex(startIndex, tracks, 'startIndex');
    }
    final request = ++_playRequest;
    final migrating = _handoverReady;
    if (migrating != null && !migrating.isCompleted) {
      _message = '正在等待组内设备连接新主控…';
      _changed();
      await migrating.future;
      if (request != _playRequest || _disposed || !isMaster) return;
    }
    final playable = <PlayableTrack>[];
    var skipped = 0;
    var firstPlayableAtOrAfterStart = -1;
    for (final entry in List<PlayableTrack>.of(tracks).indexed) {
      final track = entry.$2;
      if (track.isPlayable && await _validateTrack(track)) {
        if (entry.$1 >= startIndex && firstPlayableAtOrAfterStart < 0) {
          firstPlayableAtOrAfterStart = playable.length;
        }
        playable.add(track);
      } else {
        skipped++;
      }
    }
    if (request != _playRequest || _disposed) return;
    if (playable.isEmpty) {
      _fail('没有可播放资源，请先转换或检查文件；当前播放保持不变');
      return;
    }
    final wireTracks = playable.map((track) => track.toWire()).toList();
    final largestTrack = wireTracks.fold<int>(
      0,
      (size, track) => max(size, jsonEncode(track).length),
    );
    // reset_task includes both the full queue and the current track. Reserve
    // room for task/session IDs and modes within the bounded control channel.
    if (jsonEncode(wireTracks).length + largestTrack + 2048 > 65536) {
      _fail('播放列表过长，请拆分为较小的分组；当前播放保持不变');
      return;
    }
    if (!isConnected) {
      await createRoom();
      // createRoom intentionally invalidates any previous playback work.
      if (_disposed || !isMaster || _playRequest != request + 1) return;
    }
    _queue = List.unmodifiable(playable);
    _queueIndex = firstPlayableAtOrAfterStart < 0
        ? 0
        : firstPlayableAtOrAfterStart;
    _activePlaybackMode = _playbackMode;
    _visitedQueueIndices
      ..clear()
      ..add(_queueIndex);
    _playHistory
      ..clear()
      ..add(_queueIndex);
    _historyIndex = 0;
    _skippedCount = skipped;
    _error = null;
    _message = skipped > 0 ? '已跳过 $skipped 个不可播放条目' : null;
    await _prepareCurrent();
  }

  Future<void> _prepareCurrent() async {
    if (!isMaster || _queueIndex < 0 || _queueIndex >= _queue.length) return;
    final track = _queue[_queueIndex];
    final task = _newId();
    final session = _sessionId!;
    _taskId = task;
    _currentTrack = track;
    _phase = SessionPhase.preparing;
    _participants
      ..clear()
      ..addAll(_members.keys);
    _readyDeviceIds.clear();
    _audioStatus = const PlaybackAudioStatus(
      state: PlaybackAudioState.preparing,
    );
    _displayStartTimer?.cancel();
    _prepareTimer?.cancel();
    for (final id in _pendingJoins.keys.toList()) {
      rejectJoin(id, reason: '播放已开始准备，请等待待命状态后重新申请');
    }
    _queueRevision++;
    _broadcast('reset_task', {
      'taskId': task,
      'track': track.toWire(),
      ..._queueSnapshot(),
    });
    _prepareTimer = Timer(prepareTimeout, () {
      if (_taskId == task && _phase == SessionPhase.preparing) {
        final missing = _participants
            .difference(_readyDeviceIds)
            .map((id) => _members[id]?.name ?? id)
            .join('、');
        unawaited(endPlayback(reason: '准备超时：$missing。请重试或移出未就绪设备'));
      }
    });
    _changed();
    try {
      await audio.stop();
      if (!_isTask(session, task)) return;
      final valid = await _validateTrack(track);
      if (!_isTask(session, task)) return;
      if (!valid) {
        _skippedCount++;
        await _advanceQueue();
        return;
      }
      if (!await _gainFocus()) throw StateError('无法获得音频输出焦点');
      if (!_isTask(session, task)) return;
      final prepared = await audio.prepareMaster(
        track,
        sessionId: session,
        taskId: task,
      );
      if (!_isTask(session, task)) return;
      _applyLocalOutput();
      _readyDeviceIds.add(_localDevice.id);
      _broadcast('prepare', {
        'taskId': task,
        'track': track.toWire(),
        'audioPort': prepared.port,
        'totalFrames': prepared.totalFrames,
      });
      _maybeSchedule();
      _changed();
    } catch (error) {
      if (_isTask(session, task)) {
        await handleInterruption('无法准备音频：$error');
      }
    }
  }

  void _maybeSchedule() {
    if (!isMaster ||
        _phase != SessionPhase.preparing ||
        _taskId == null ||
        _participants.isEmpty ||
        !_participants.every(_readyDeviceIds.contains)) {
      return;
    }
    _prepareTimer?.cancel();
    final startTime = audio.monotonicMicros + startLead.inMicroseconds;
    try {
      _broadcast('start', {'taskId': _taskId, 'startTimeUs': startTime});
      audio.scheduleStart(startTime);
      _markScheduled();
    } catch (error) {
      unawaited(handleInterruption('无法安排共同开始时间：$error'));
    }
  }

  void _markScheduled() {
    _phase = SessionPhase.scheduled;
    _changed();
    // UI-only timer. Actual playback is scheduled by the native audio clock.
    final task = _taskId;
    _displayStartTimer?.cancel();
    _displayStartTimer = Timer(startLead, () {
      if (_taskId == task &&
          _phase == SessionPhase.scheduled &&
          _audioStatus.state == PlaybackAudioState.playing) {
        _phase = SessionPhase.playing;
        _changed();
      }
    });
  }

  Future<void> _prepareFollower(Map<String, dynamic> message) async {
    final connection = _masterConnection;
    final task = message['taskId'] as String;
    final session = message['sessionId'] as String;
    if (connection == null ||
        !_isTask(session, task) ||
        _phase != SessionPhase.preparing ||
        _readyDeviceIds.contains(_localDevice.id)) {
      return;
    }
    try {
      await audio.stop();
      if (!_isTask(session, task)) return;
      if (!await _gainFocus()) throw StateError('无法获得音频输出焦点');
      if (!_isTask(session, task)) return;
      await audio.prepareFollower(
        host: connection.address,
        port: message['audioPort'] as int,
        sessionId: session,
        taskId: task,
      );
      if (!_isTask(session, task)) return;
      _applyLocalOutput();
      _readyDeviceIds.add(_localDevice.id);
      connection.send('ready', {'sessionId': session, 'taskId': task});
      _changed();
    } catch (error) {
      if (_isTask(session, task)) {
        await handleInterruption('音频准备失败：$error');
      }
    }
  }

  Future<bool> _gainFocus() {
    // A resource change belongs to the same media session. In particular, it
    // must not reclaim focus from another app while our output is attenuated.
    final pending = _focusAcquisition;
    if (pending != null) return pending;
    if (_focusSessionActive) return Future.value(true);
    final generation = ++_focusGeneration;
    _focusSessionActive = true;
    _focusAttenuation = 1;
    final acquisition = _requestFocus(generation);
    _focusAcquisition = acquisition;
    return acquisition.whenComplete(() {
      if (identical(_focusAcquisition, acquisition)) _focusAcquisition = null;
    });
  }

  Future<bool> _requestFocus(int generation) async {
    try {
      // Android 15+ requires a foreground media service before a background
      // app may request focus. Establish the playback lifetime first.
      await setPlaybackActive?.call(true);
      if (generation != _focusGeneration || _disposed) return false;
      final granted = await acquireAudioFocus?.call() ?? true;
      if (generation != _focusGeneration || _disposed) return false;
      if (!granted) await _releaseFocus();
      return granted;
    } catch (_) {
      if (generation == _focusGeneration) await _releaseFocus();
      rethrow;
    }
  }

  Future<void> _releaseFocus() async {
    final generation = ++_focusGeneration;
    _focusSessionActive = false;
    _focusAcquisition = null;
    _focusRestoration = null;
    // Do not apply this reset to an old stream that may still be draining.
    // The next preparation applies the current user settings before starting.
    _focusAttenuation = 1;
    try {
      await releaseAudioFocus?.call();
    } finally {
      // A new playback request may have started while release was awaiting
      // the platform. Its foreground service must not be stopped by this one.
      if (generation == _focusGeneration) {
        await setPlaybackActive?.call(false);
      }
    }
  }

  Future<void> _stopAndReleaseFocus() async {
    // Close the focus lease synchronously with submitting the native stop.
    // Waiting for a slow stop first would let a new task reuse that lease,
    // only for the old continuation to release the new task's media service.
    // Native stop/prepare operations are ordered by the engine's own queue.
    final stopping = Future<void>.sync(audio.stop);
    final releasing = _releaseFocus();
    await Future.wait([stopping, releasing]);
  }

  /// Temporary OS focus policy affects this output only. The synchronized
  /// stream continues consuming frames; user volume/mute and group metadata
  /// stay unchanged, including edits made while another app is audible.
  void setFocusAttenuation(double gain) {
    if (_disposed || !_focusSessionActive || !gain.isFinite) return;
    _focusChangeRevision++;
    final value = gain.clamp(0.0, 1.0);
    if (value == _focusAttenuation) return;
    _focusAttenuation = value;
    if (value == 1 && _message == _focusRecoveryFailure) _message = null;
    _applyLocalOutput();
    // Refresh only local UI. This does not advertise or broadcast output
    // changes, and saved volume/mute remain the user's settings.
    if (!_notifierDisposed) notifyListeners();
  }

  /// Explicit user recovery when the OS cannot identify when another player
  /// finishes. Never starts/restarts a track or alters the user's output gain.
  Future<void> restoreLocalAudioFocus() {
    final pending = _focusRestoration;
    if (pending != null) return pending;
    if (_disposed ||
        !_focusSessionActive ||
        !membersLocked ||
        _focusAttenuation >= 1 ||
        resumeAudioFocus == null) {
      return Future.value();
    }
    final restoration = _restoreFocus(_focusGeneration, _focusChangeRevision);
    _focusRestoration = restoration;
    return restoration.whenComplete(() {
      if (identical(_focusRestoration, restoration)) _focusRestoration = null;
    });
  }

  Future<void> _restoreFocus(int generation, int revision) async {
    var granted = false;
    try {
      granted = await resumeAudioFocus!();
    } catch (_) {
      // A rejected platform request affects local audibility only.
    }
    if (_disposed ||
        generation != _focusGeneration ||
        revision != _focusChangeRevision ||
        !_focusSessionActive ||
        !membersLocked) {
      return;
    }
    if (granted) {
      setFocusAttenuation(1);
    } else {
      _message = _focusRecoveryFailure;
      _changed();
    }
  }

  /// Choosing a mode changes only the next transition, never this task.
  void setPlaybackMode(PlaybackMode mode) {
    if (!canSelectResources || mode == _playbackMode) return;
    _playbackMode = mode;
    _queueRevision++;
    _broadcast('queue_state', {'taskId': _taskId, ..._queueSnapshot()});
    _changed();
  }

  Future<void> nextTrack() async {
    if (!canNextTrack) return;
    await _advanceQueue();
  }

  Future<void> previousTrack() async {
    if (!canPreviousTrack) return;
    if (_activePlaybackMode == PlaybackMode.sequential) {
      final previous = _queueIndex - 1;
      if (_historyIndex > 0 && _playHistory[_historyIndex - 1] == previous) {
        _historyIndex--;
        await _switchQueueIndex(
          previous,
          recordHistory: false,
          applyMode: false,
        );
      } else {
        await _switchQueueIndex(previous, applyMode: false);
      }
    } else {
      _historyIndex--;
      await _switchQueueIndex(
        _playHistory[_historyIndex],
        recordHistory: false,
        applyMode: false,
      );
    }
  }

  Future<void> selectQueueTrack(int index) async {
    if (!canSelectResources ||
        index < 0 ||
        index >= _queue.length ||
        index == _queueIndex) {
      return;
    }
    await _switchQueueIndex(index);
  }

  Future<void> _advanceQueue() async {
    if (!isMaster || _queue.isEmpty) return;
    if (!_hasNextTrack) {
      await endPlayback(reason: '播放列表已完成');
      return;
    }
    if (!modeChangePending && _historyIndex + 1 < _playHistory.length) {
      _historyIndex++;
      await _switchQueueIndex(
        _playHistory[_historyIndex],
        recordHistory: false,
      );
      return;
    }
    final int next;
    if (_playbackMode == PlaybackMode.random) {
      final remaining = List.generate(
        _queue.length,
        (i) => i,
      ).where((i) => !_visitedQueueIndices.contains(i)).toList();
      next = remaining[_queueRandom.nextInt(remaining.length)];
    } else {
      next = _queueIndex + 1;
    }
    await _switchQueueIndex(next);
  }

  Future<void> _switchQueueIndex(
    int index, {
    bool recordHistory = true,
    bool applyMode = true,
  }) async {
    // Invalidate old validation/READY/completion work before the first await.
    _playRequest++;
    _queueIndex = index;
    if (applyMode) _activePlaybackMode = _playbackMode;
    _visitedQueueIndices.add(index);
    if (recordHistory) {
      _playHistory.removeRange(_historyIndex + 1, _playHistory.length);
      _playHistory.add(index);
      _historyIndex = _playHistory.length - 1;
    }
    await _prepareCurrent();
  }

  Future<void> endPlayback({
    String reason = '播放已结束，允许新设备加入',
    bool requireMasterSelection = false,
  }) async {
    if (!isMaster) {
      if (isConnected) _fail('只有主控可以结束全组播放；本机可退出播放组');
      return;
    }
    if (requireMasterSelection) _masterSelectionRequired = true;
    _broadcast('stop', {
      'taskId': _taskId,
      'reason': reason,
      'masterSelectionRequired': _masterSelectionRequired,
    });
    _clearPlayback();
    _phase = SessionPhase.standby;
    _message = reason;
    _changed();
    await _stopAndReleaseFocus();
  }

  void _clearPlayback() {
    _playRequest++;
    _taskId = null;
    _currentTrack = null;
    _queue = [];
    _queueIndex = -1;
    _visitedQueueIndices.clear();
    _playHistory.clear();
    _historyIndex = -1;
    _activePlaybackMode = _playbackMode;
    _participants.clear();
    _readyDeviceIds.clear();
    _prepareTimer?.cancel();
    _displayStartTimer?.cancel();
    _audioStatus = const PlaybackAudioStatus(state: PlaybackAudioState.idle);
  }

  Future<void> handleInterruption(String reason) async {
    if (!isConnected && !_joining) return;
    if (isMaster) {
      await endPlayback(
        reason: '主控中断：$reason；全组已停止，请在设备页重新选择主控',
        requireMasterSelection: true,
      );
    } else {
      await leave(reason: '本机已停止并退出：$reason');
    }
  }

  /// Explicit user selection after an interruption. Keeping the old control
  /// connection only coordinates this decision; it cannot authorize playback.
  void confirmMasterSelection() {
    if (!isMaster || !_masterSelectionRequired || membersLocked) return;
    _masterSelectionRequired = false;
    _error = null;
    _message = '已重新选择本机为主控，等待选择资源';
    _broadcast('master_selected', {'masterId': _masterId});
    _changed();
  }

  Future<void> leave({String? reason}) => _leave(reason: reason);

  Future<void> _leave({
    String? reason,
    bool invalidateConnectionAttempt = true,
  }) async {
    if (invalidateConnectionAttempt) ++_connectionAttempt;
    final wasMaster = isMaster;
    if (wasMaster) {
      _broadcast('room_closed', {'reason': reason ?? '主控已解散播放组'});
    } else {
      _masterConnection?.send('leave', {'sessionId': _sessionId});
    }
    final oldConnections = _connections.toList();
    _masterConnection = null;
    _peers.clear();
    _pendingJoins.clear();
    _members.clear();
    _expectedRejoins.clear();
    if (_handoverReady != null && !_handoverReady!.isCompleted) {
      _handoverReady!.complete();
    }
    _handoverReady = null;
    if (_migrationAcceptance != null && !_migrationAcceptance!.isCompleted) {
      _migrationAcceptance!.complete(false);
    }
    _migrationAcceptance = null;
    _handoverToken = null;
    _handoverExpiry?.cancel();
    _takeoverRequester = null;
    _sessionId = null;
    _masterId = null;
    _masterSelectionRequired = false;
    _joining = false;
    _clearPlayback();
    _phase = SessionPhase.disconnected;
    _message = reason;
    _changed();
    await _stopAndReleaseFocus();
    for (final connection in oldConnections) {
      _connections.remove(connection);
      unawaited(connection.dispose());
    }
  }

  Future<void> _lostMaster(String reason) async {
    final leaving = leave(reason: reason);
    final attempt = _connectionAttempt;
    await leaving;
    if (attempt != _connectionAttempt || isConnected || _disposed) return;
    _error = reason;
    _changed();
  }

  void requestTakeover() {
    if (!isConnected || isMaster) return;
    _masterConnection?.send('takeover_request', {'sessionId': _sessionId});
    _message = '已申请接管，等待主控确认';
    _changed();
  }

  Future<void> approveTakeover() async {
    if (!isMaster || _takeoverRequester == null) return;
    final next = _members[_takeoverRequester];
    if (next == null || !_peers.containsKey(next.id)) {
      _takeoverRequester = null;
      return;
    }
    final payload = <String, Object?>{
      'newSessionId': _newId(),
      'masterId': next.id,
      'token': _newId(),
      'members': _members.values.map((d) => d.toJson()).toList(),
    };
    _broadcast('handover', payload);
    await _applyHandover(payload);
  }

  void rejectTakeover() {
    if (!isMaster || _takeoverRequester == null) return;
    _peers[_takeoverRequester]?.send('notice', {
      'sessionId': _sessionId,
      'reason': '主控暂未接受接管申请',
    });
    _takeoverRequester = null;
    _changed();
  }

  Future<void> _applyHandover(Map<String, dynamic> payload) async {
    final newSession = payload['newSessionId'] as String;
    final newMasterId = payload['masterId'] as String;
    final token = payload['token'] as String;
    final preserved = (payload['members'] as List)
        .map((d) => DeviceMember.fromJson(Map<String, dynamic>.from(d as Map)))
        .toList();
    if (!preserved.any((d) => d.id == newMasterId) ||
        !preserved.any((d) => d.id == _localDevice.id) ||
        preserved.length > 6) {
      return;
    }
    final next = preserved.firstWhere((d) => d.id == newMasterId);
    final attempt = ++_connectionAttempt;
    final oldConnections = _connections.toList();
    _masterConnection = null;
    _peers.clear();
    _pendingJoins.clear();
    _clearPlayback();
    _takeoverRequester = null;
    _sessionId = newSession;
    _masterId = newMasterId;
    _masterSelectionRequired = false;
    _members
      ..clear()
      ..addEntries(preserved.map((d) => MapEntry(d.id, d)));
    _localDevice = _members[_localDevice.id]!;
    _phase = SessionPhase.standby;
    if (isMaster) {
      _handoverToken = token;
      _expectedRejoins
        ..clear()
        ..addAll(_members.keys.where((id) => id != _localDevice.id));
      _handoverReady = Completer<void>();
      if (_expectedRejoins.isEmpty) _handoverReady!.complete();
    }
    _message = '主控已切换，旧播放已清除，等待新主控选择资源';
    _changed();
    await _stopAndReleaseFocus();
    if (_sessionId != newSession ||
        attempt != _connectionAttempt ||
        _disposed) {
      return;
    }
    for (final connection in oldConnections) {
      _connections.remove(connection);
      unawaited(connection.dispose());
    }
    if (isMaster) {
      _handoverExpiry?.cancel();
      final handoverReady = _handoverReady!;
      _handoverExpiry = Timer(heartbeatTimeout, () {
        if (_sessionId != newSession ||
            _handoverReady != handoverReady ||
            !isMaster) {
          return;
        }
        for (final id in _expectedRejoins.toList()) {
          _removeMember(id, '部分设备未能连接新主控，已退出');
        }
        _expectedRejoins.clear();
        _handoverToken = null;
        if (!handoverReady.isCompleted) handoverReady.complete();
      });
      return;
    }
    // All members already run a listener. Retry only the authorized migration,
    // never automatically join a different/new session after a disconnection.
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < heartbeatTimeout) {
      if (_sessionId != newSession ||
          attempt != _connectionAttempt ||
          _disposed) {
        return;
      }
      try {
        final connection = await ControlServer.connect(next.address, next.port);
        if (_sessionId != newSession ||
            attempt != _connectionAttempt ||
            _disposed) {
          await connection.dispose();
          return;
        }
        final acceptance = Completer<bool>();
        _migrationAcceptance = acceptance;
        _attachMaster(connection);
        connection.send('rejoin', {
          'sessionId': newSession,
          'token': token,
          'device': _localDevice.toJson(),
        });
        final accepted = await acceptance.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        if (accepted) return;
        if (_masterConnection == connection) _masterConnection = null;
        if (_migrationAcceptance == acceptance) _migrationAcceptance = null;
        unawaited(connection.dispose());
        // The target's listener exists before it processes HANDOVER; a TCP
        // connection can succeed while that target is still the old slave.
        // Retry the authorized session handshake, not just the TCP connect.
      } catch (_) {
        if (_sessionId != newSession ||
            attempt != _connectionAttempt ||
            _disposed) {
          return;
        }
        _migrationAcceptance = null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_sessionId == newSession && attempt == _connectionAttempt) {
      await _lostMaster('无法连接新主控，请重新加入');
    }
  }

  void setOutput({
    String? deviceId,
    double? volume,
    AudioChannel? channel,
    bool? muted,
  }) {
    final id = deviceId ?? _localDevice.id;
    if (!isMaster && id != _localDevice.id) return;
    final current = id == _localDevice.id ? _localDevice : _members[id];
    if (current == null) return;
    final updated = current.copyWith(
      volume: volume?.clamp(0, 1),
      channel: channel,
      muted: muted,
    );
    if (id == _localDevice.id) {
      _localDevice = updated;
      _applyLocalOutput();
    }
    if (_members.containsKey(id)) _members[id] = updated;
    if (isMaster) {
      _broadcastMembers();
    } else if (isConnected) {
      _masterConnection?.send('output', {
        'sessionId': _sessionId,
        'volume': updated.volume,
        'channel': updated.channel.name,
        'muted': updated.muted,
      });
    }
    _changed();
  }

  void rename(String name) {
    final value = name.trim();
    if (value.isEmpty || value.length > 64) {
      _fail('设备名称应为 1 至 64 个字符');
      return;
    }
    _localDevice = _localDevice.copyWith(name: value);
    if (_members.containsKey(_localDevice.id)) {
      _members[_localDevice.id] = _localDevice;
    }
    if (isMaster) {
      _broadcastMembers();
    } else {
      _masterConnection?.send('rename', {
        'sessionId': _sessionId,
        'name': value,
      });
    }
    _changed();
  }

  void clearNotice() {
    _message = null;
    _error = null;
    _changed();
  }

  void _applyLocalOutput() => audio.setOutput(
    volume: _localDevice.volume * _focusAttenuation,
    channel: _localDevice.channel,
    muted: _localDevice.muted,
  );

  Map<String, Object?> _snapshot() => {
    'sessionId': _sessionId,
    'masterId': _masterId,
    'masterSelectionRequired': _masterSelectionRequired,
    'members': _members.values.map((d) => d.toJson()).toList(),
    'playbackMode': _playbackMode.name,
  };

  Map<String, Object?> _queueSnapshot() => {
    'queueRevision': _queueRevision,
    'queue': _queue.map((track) => track.toWire()).toList(),
    'queueIndex': _queueIndex,
    'playbackMode': _playbackMode.name,
    'activePlaybackMode': _activePlaybackMode.name,
    'skippedCount': _skippedCount,
  };

  void _readQueueSnapshot(Map<String, dynamic> message) {
    final tracks = (message['queue'] as List)
        .map(
          (item) =>
              PlayableTrack.fromWire(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    final index = message['queueIndex'] as int;
    if ((tracks.isEmpty && index != -1) ||
        (tracks.isNotEmpty && (index < 0 || index >= tracks.length))) {
      throw const FormatException('Invalid queue index');
    }
    final mode = PlaybackMode.values.byName(message['playbackMode'] as String);
    final active = PlaybackMode.values.byName(
      message['activePlaybackMode'] as String,
    );
    _queue = List.unmodifiable(tracks);
    _queueIndex = index;
    _playbackMode = mode;
    _activePlaybackMode = active;
    _skippedCount = message['skippedCount'] as int? ?? 0;
    _receivedQueueRevision = message['queueRevision'] as int;
  }

  void _broadcast(String type, Map<String, Object?> payload) {
    for (final peer in _peers.values.toList()) {
      if (peer.accepted) peer.send(type, {'sessionId': _sessionId, ...payload});
    }
  }

  void _broadcastMembers() {
    _broadcast('members', {
      'members': _members.values.map((d) => d.toJson()).toList(),
      'readyIds': _readyDeviceIds.toList(),
    });
  }

  bool _isTask(String session, String task) =>
      !_disposed && _sessionId == session && _taskId == task;

  void _onPeerMessage(
    ControlConnection connection,
    Map<String, dynamic> message,
  ) {
    final type = message['type'] as String;
    if (type == 'join' || type == 'rejoin') {
      if (connection.deviceId != null) {
        throw const FormatException('Already joined');
      }
      _handleJoin(connection, message, migration: type == 'rejoin');
      return;
    }
    if (type == 'ping') {
      connection.send('pong', {});
      return;
    }
    if (type == 'pong') return;
    final id = connection.deviceId;
    if (!isMaster ||
        !connection.accepted ||
        id == null ||
        _peers[id] != connection ||
        message['sessionId'] != _sessionId) {
      return;
    }
    switch (type) {
      case 'ready':
        if (_phase == SessionPhase.preparing &&
            message['taskId'] == _taskId &&
            _participants.contains(id)) {
          _readyDeviceIds.add(id);
          _broadcastMembers();
          _maybeSchedule();
          _changed();
        }
      case 'leave':
        _peers.remove(id);
        unawaited(connection.close());
        _removeMember(id, '${_members[id]?.name ?? '设备'} 已退出，请检查声道分配');
      case 'takeover_request':
        if (_takeoverRequester == null) {
          _takeoverRequester = id;
          _changed();
        } else if (_takeoverRequester != id) {
          connection.send('notice', {
            'sessionId': _sessionId,
            'reason': '已有接管申请正在处理',
          });
        }
      case 'output':
        setOutput(
          deviceId: id,
          volume: (message['volume'] as num).toDouble(),
          channel: AudioChannel.values.byName(message['channel'] as String),
          muted: message['muted'] as bool,
        );
      case 'rename':
        final name = message['name'] as String;
        if (name.trim().isEmpty || name.length > 64) return;
        _members[id] = _members[id]!.copyWith(name: name.trim());
        _broadcastMembers();
        _changed();
    }
  }

  void _handleJoin(
    ControlConnection connection,
    Map<String, dynamic> message, {
    required bool migration,
  }) {
    if (!isMaster) {
      connection.send('rejected', {'reason': '此设备当前不是主控'});
      unawaited(connection.close());
      return;
    }
    final proposed = DeviceMember.fromJson(
      Map<String, dynamic>.from(message['device'] as Map),
    );
    if (proposed.id.isEmpty ||
        proposed.id.length > 128 ||
        proposed.name.isEmpty ||
        proposed.name.length > 64 ||
        proposed.port < 1 ||
        proposed.port > 65535) {
      throw const FormatException('Invalid device');
    }
    final allowedMigration =
        migration &&
        message['sessionId'] == _sessionId &&
        message['token'] == _handoverToken &&
        _handoverToken != null &&
        _expectedRejoins.contains(proposed.id);
    if (migration && !allowedMigration) {
      connection.send('rejected', {'reason': '主控移交凭证已失效，请重新申请加入'});
      unawaited(connection.close());
      return;
    }
    if (membersLocked ||
        (!allowedMigration && _members.length >= 6) ||
        (!allowedMigration && _members.containsKey(proposed.id)) ||
        _peers.containsKey(proposed.id) ||
        _pendingJoins.length >= 12) {
      connection.send('rejected', {
        'reason': membersLocked ? '播放期间禁止加入，请等待待命状态' : '播放组已满或设备已连接',
      });
      unawaited(connection.close());
      return;
    }
    final device = proposed.copyWith(address: connection.address);
    connection.deviceId = device.id;
    _peers[device.id] = connection;
    if (allowedMigration) {
      connection.accepted = true;
      _expectedRejoins.remove(device.id);
      if (_expectedRejoins.isEmpty &&
          _handoverReady != null &&
          !_handoverReady!.isCompleted) {
        _handoverReady!.complete();
      }
      // Retain the master's approved channel/volume, update only routing details.
      _members[device.id] = _members[device.id]!.copyWith(
        address: device.address,
        port: device.port,
      );
      connection.send('welcome', _snapshot());
      _broadcastMembers();
    } else {
      _pendingJoins[device.id] = JoinRequest(
        device: device,
        receivedAt: DateTime.now(),
      );
      connection.send('pending', {});
    }
    _changed();
  }

  void _onMasterMessage(
    ControlConnection connection,
    Map<String, dynamic> message,
  ) {
    if (_masterConnection != connection || _disposed) return;
    final type = message['type'] as String;
    if (type == 'ping') {
      connection.send('pong', {});
      return;
    }
    if (type == 'pong' || type == 'pending') return;
    if (type == 'rejected') {
      final migration = _migrationAcceptance;
      if (migration != null && !migration.isCompleted) {
        _masterConnection = null;
        migration.complete(false);
        unawaited(connection.dispose());
        return;
      }
      unawaited(_lostMaster(message['reason'] as String));
      return;
    }
    if (type == 'welcome') {
      if (isConnected && message['sessionId'] != _sessionId) return;
      final incoming = _parseMembers(message);
      final masterId = message['masterId'] as String;
      if (!incoming.containsKey(_localDevice.id) ||
          !incoming.containsKey(masterId)) {
        throw const FormatException('Invalid group');
      }
      _sessionId = message['sessionId'] as String;
      _masterId = masterId;
      _masterSelectionRequired = message['masterSelectionRequired'] == true;
      _playbackMode = PlaybackMode.values.byName(
        message['playbackMode'] as String? ?? 'sequential',
      );
      _activePlaybackMode = _playbackMode;
      _receivedQueueRevision = -1;
      _members
        ..clear()
        ..addAll(incoming);
      _localDevice = _members[_localDevice.id]!;
      _phase = SessionPhase.standby;
      _joining = false;
      _message = _masterSelectionRequired ? '全组已待命，请重新选择主控' : '已连接，等待主控选择资源';
      _error = null;
      _applyLocalOutput();
      final migration = _migrationAcceptance;
      _migrationAcceptance = null;
      if (migration != null && !migration.isCompleted) migration.complete(true);
      _changed();
      return;
    }
    if (!isConnected || isMaster || message['sessionId'] != _sessionId) return;
    switch (type) {
      case 'members':
        final incoming = _parseMembers(message);
        if (!incoming.containsKey(_localDevice.id)) {
          unawaited(leave(reason: '本机已被移出播放组'));
          return;
        }
        _members
          ..clear()
          ..addAll(incoming);
        _localDevice = _members[_localDevice.id]!;
        _readyDeviceIds
          ..clear()
          ..addAll((message['readyIds'] as List).cast<String>());
        _applyLocalOutput();
        _changed();
      case 'reset_task':
        if (_masterSelectionRequired) return;
        final task = message['taskId'] as String;
        final revision = message['queueRevision'] as int?;
        if (task == _taskId ||
            (revision != null && revision <= _receivedQueueRevision)) {
          return;
        }
        _clearPlayback();
        _taskId = task;
        _currentTrack = PlayableTrack.fromWire(
          Map<String, dynamic>.from(message['track'] as Map),
        );
        if (revision != null) {
          _readQueueSnapshot(message);
        } else {
          // Display a useful queue when following an older app version.
          _queue = [_currentTrack!];
          _queueIndex = 0;
        }
        _phase = SessionPhase.preparing;
        _participants.addAll(_members.keys);
        _audioStatus = const PlaybackAudioStatus(
          state: PlaybackAudioState.preparing,
        );
        unawaited(audio.stop());
        final session = _sessionId;
        _prepareTimer = Timer(prepareTimeout, () {
          if (_sessionId == session &&
              _taskId == task &&
              _phase == SessionPhase.preparing) {
            unawaited(handleInterruption('等待主控准备超时'));
          }
        });
        _changed();
      case 'queue_state':
        if (message['taskId'] != _taskId ||
            (message['queueRevision'] as int) <= _receivedQueueRevision) {
          return;
        }
        _readQueueSnapshot(message);
        _changed();
      case 'prepare':
        if (message['taskId'] == _taskId) unawaited(_prepareFollower(message));
      case 'start':
        if (message['taskId'] != _taskId ||
            _phase != SessionPhase.preparing ||
            !_readyDeviceIds.contains(_localDevice.id)) {
          return;
        }
        _prepareTimer?.cancel();
        try {
          audio.scheduleStart(message['startTimeUs'] as int);
          _markScheduled();
        } catch (error) {
          unawaited(handleInterruption('无法预约音频开始：$error'));
        }
      case 'stop':
        if (message['taskId'] != _taskId) return;
        _clearPlayback();
        _phase = SessionPhase.standby;
        _masterSelectionRequired = message['masterSelectionRequired'] == true;
        _message = message['reason'] as String?;
        unawaited(_stopAndReleaseFocus());
        _changed();
      case 'master_selected':
        if (message['masterId'] != _masterId ||
            _phase != SessionPhase.standby) {
          return;
        }
        _masterSelectionRequired = false;
        _message = '已重新选择主控，等待选择资源';
        _changed();
      case 'room_closed':
      case 'removed':
        unawaited(_lostMaster(message['reason'] as String));
      case 'handover':
        unawaited(_applyHandover(message));
      case 'notice':
        _message = message['reason'] as String;
        _changed();
    }
  }

  Map<String, DeviceMember> _parseMembers(Map<String, dynamic> message) {
    final list = message['members'] as List;
    if (list.isEmpty || list.length > 6) {
      throw const FormatException('Invalid capacity');
    }
    final devices = list.map(
      (d) => DeviceMember.fromJson(Map<String, dynamic>.from(d as Map)),
    );
    final result = {for (final device in devices) device.id: device};
    if (result.length != list.length) {
      throw const FormatException('Duplicate member');
    }
    return result;
  }

  void _heartbeat() {
    if (_disposed) return;
    for (final connection in _connections.toList()) {
      if (connection.closed) continue;
      if (connection.lastReceived.elapsed > heartbeatTimeout) {
        if (connection == _masterConnection) {
          unawaited(_lostMaster('主控心跳超时，已停止旧播放，请重新建组'));
        } else {
          unawaited(connection.close(WebSocketStatus.goingAway));
        }
      } else {
        connection.send('ping', {});
      }
    }
    if (isMaster) {
      final now = DateTime.now();
      for (final pending in _pendingJoins.values.toList()) {
        if (now.difference(pending.receivedAt) > const Duration(seconds: 60)) {
          rejectJoin(pending.id, reason: '加入申请已超时，请重新申请');
        }
      }
    }
  }

  void _onAudioStatus(PlaybackAudioStatus status) {
    if (_disposed || !membersLocked || _taskId == null) return;
    if (status.taskId != null && status.taskId != _taskId) return;
    final previous = _audioStatus.state;
    _audioStatus = status;
    if (status.state == PlaybackAudioState.playing &&
        (_phase == SessionPhase.scheduled || _phase == SessionPhase.playing)) {
      _phase = SessionPhase.playing;
    } else if (status.state == PlaybackAudioState.failed &&
        previous != PlaybackAudioState.failed) {
      unawaited(handleInterruption(status.error ?? '音频输出中断或缓冲耗尽'));
    } else if (status.state == PlaybackAudioState.completed &&
        previous != PlaybackAudioState.completed &&
        isMaster &&
        (_phase == SessionPhase.playing || _phase == SessionPhase.scheduled)) {
      unawaited(_advanceQueue());
    }
    _changed();
  }

  void _fail(String message) {
    _error = message;
    _changed();
  }

  void _changed() {
    if (!_disposed && !_notifierDisposed) {
      _discovery?.advertise(
        isMaster ? _localDevice : null,
        memberCount: _members.length,
        locked: membersLocked,
      );
      notifyListeners();
    }
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    await leave();
    _disposed = true;
    _heartbeatTimer?.cancel();
    _prepareTimer?.cancel();
    _displayStartTimer?.cancel();
    _handoverExpiry?.cancel();
    await _audioSubscription?.cancel();
    await _server.close();
    await _discovery?.close();
    await audio.dispose();
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(shutdown());
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }
}
