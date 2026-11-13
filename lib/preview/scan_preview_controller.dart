import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/media_scan.dart';
import 'preview_controller.dart';

abstract interface class ScanPreviewAccess {
  Future<PreparedPreviewSource> prepare(MediaScanEntry entry);
  Future<void> cancel();
}

/// Windows reads the selected original. Android prepares a private, disposable
/// audio copy; this path never writes a library record or converts a video.
class SystemScanPreviewAccess implements ScanPreviewAccess {
  SystemScanPreviewAccess({
    TargetPlatform? platform,
    MethodChannel? channel,
    Future<Directory> Function()? temporaryDirectory,
  }) : _platform = platform ?? defaultTargetPlatform,
       _channel = channel ?? const MethodChannel('heming_media_scan'),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final TargetPlatform _platform;
  final MethodChannel _channel;
  final Future<Directory> Function() _temporaryDirectory;
  Future<void> _operations = Future<void>.value();
  int _generation = 0;
  bool _copying = false;

  @override
  Future<PreparedPreviewSource> prepare(MediaScanEntry entry) {
    if (entry.category != 'audio') {
      return Future.error(const PreviewSourceFailure('仅支持音频预览。'));
    }
    final generation = ++_generation;
    final work = _operations.then((_) => _prepare(entry, generation));
    // Serialize preparations so a cancelled native copy finishes releasing its
    // file descriptor before the replacement copy begins.
    _operations = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  void _check(int generation) {
    if (generation != _generation) throw const MediaScanCancelled();
  }

  Future<PreparedPreviewSource> _prepare(
    MediaScanEntry entry,
    int generation,
  ) async {
    _check(generation);
    if (_platform != TargetPlatform.android) {
      final file = File(entry.locator);
      final stat = await file.stat();
      _check(generation);
      if (stat.type != FileSystemEntityType.file ||
          stat.size != entry.sizeBytes ||
          stat.modified.millisecondsSinceEpoch != entry.modifiedMs) {
        throw const PreviewSourceFailure('文件已变化或不再存在，请刷新扫描列表。');
      }
      return PreparedPreviewSource(path: file.path);
    }

    Directory? temporary;
    try {
      final parent = await _temporaryDirectory();
      _check(generation);
      temporary = await parent.createTemp('heming-scan-preview-');
      _check(generation);
      final suffix = p.extension(entry.name).toLowerCase();
      final extension = RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(suffix)
          ? suffix
          : '.audio';
      final destination = p.join(temporary.path, 'preview$extension');
      _copying = true;
      try {
        await _channel.invokeMethod<void>('copyPreviewMedia', {
          'uri': entry.locator,
          'destination': destination,
          'expectedSize': entry.sizeBytes,
          'expectedModifiedMs': entry.modifiedMs,
        });
      } finally {
        _copying = false;
      }
      _check(generation);
      final ownedDirectory = temporary;
      return PreparedPreviewSource(
        path: destination,
        release: () async {
          if (await ownedDirectory.exists()) {
            await ownedDirectory.delete(recursive: true);
          }
        },
      );
    } catch (error) {
      if (temporary != null && await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
      if (error is MediaScanCancelled) rethrow;
      if (error is PlatformException) {
        throw PreviewSourceFailure(switch (error.code) {
          'source_changed' => '文件已变化或不再存在，请刷新扫描列表。',
          'copy_permission' => '暂时无法读取此音频，请重新授权或选择其他文件。',
          _ => '无法准备音频预览，可尝试用其他播放器打开。',
        });
      }
      throw const PreviewSourceFailure('无法准备音频预览，请检查文件权限和剩余空间。');
    }
  }

  @override
  Future<void> cancel() async {
    ++_generation;
    if (_platform == TargetPlatform.android && _copying) {
      await _channel.invokeMethod<void>('cancelPreviewCopy');
    }
  }
}

/// Uses the application's foreground-only player without owning its lifetime.
/// A reservation in [PreviewController] lets existing app-wide stop calls also
/// cancel Android URI preparation before the first sample can be played.
class ScanPreviewController extends ChangeNotifier {
  ScanPreviewController({
    required this._player,
    ScanPreviewAccess? access,
  }) : _access = access ?? SystemScanPreviewAccess() {
    _player.addListener(_onPlayerChanged);
  }

  final PreviewController _player;
  final ScanPreviewAccess _access;
  MediaScanEntry? _entry;
  String? _requestId;
  int _sequence = 0;
  bool _closed = false;
  Future<void>? _closing;

  bool get _ownsPlayer => _requestId != null && _player.itemId == _requestId;
  MediaScanEntry? get entry => _ownsPlayer ? _entry : null;
  PreviewState get state => _ownsPlayer ? _player.state : PreviewState.idle;
  int get positionMs => _ownsPlayer ? _player.positionMs : 0;
  int get durationMs => _ownsPlayer ? _player.durationMs : 0;
  String? get error => _ownsPlayer ? _player.error : null;
  bool get isActive => entry != null;
  bool get allowed => !_closed && _player.allowed;

  void _onPlayerChanged() {
    if (!_ownsPlayer) {
      _entry = null;
      _requestId = null;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> play(MediaScanEntry entry) {
    if (!allowed || entry.category != 'audio') return Future<void>.value();
    _entry = entry;
    _requestId = 'scan-preview:${identityHashCode(this)}:${++_sequence}';
    return _player.playSource(
      id: _requestId!,
      durationMs: entry.durationMs,
      prepare: () => _access.prepare(entry),
      cancelPrepare: _access.cancel,
    );
  }

  Future<void> togglePause() {
    final current = entry;
    if (current == null) return Future<void>.value();
    if (state == PreviewState.failed || state == PreviewState.completed) {
      return play(current);
    }
    return _player.togglePause();
  }

  Future<void> seek(int positionMs) =>
      _ownsPlayer ? _player.seek(positionMs) : Future<void>.value();

  Future<void> stop() {
    final owned = _ownsPlayer;
    _entry = null;
    _requestId = null;
    if (!_closed) notifyListeners();
    return owned ? _player.stop() : Future<void>.value();
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _player.removeListener(_onPlayerChanged);
    return _closing = stop().whenComplete(super.dispose);
  }
}
