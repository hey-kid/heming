import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A source listing, not a resource owned by the application yet.
class MediaScanEntry {
  const MediaScanEntry({
    required this.sourceId,
    required this.locator,
    required this.name,
    required this.category,
    required this.sizeBytes,
    required this.modifiedMs,
    this.durationMs = 0,
    this.folder = '',
  });

  final String sourceId, locator, name, category, folder;
  final int sizeBytes, modifiedMs, durationMs;

  /// Metadata changes make a previously imported source selectable again.
  String get sourceKey => jsonEncode([sourceId, sizeBytes, modifiedMs]);

  factory MediaScanEntry.fromMap(Map<dynamic, dynamic> value) => MediaScanEntry(
    sourceId: value['sourceId'] as String,
    locator: value['locator'] as String,
    name: value['name'] as String,
    category: value['category'] == 'video' ? 'video' : 'audio',
    sizeBytes: (value['sizeBytes'] as num?)?.toInt() ?? 0,
    modifiedMs: (value['modifiedMs'] as num?)?.toInt() ?? 0,
    durationMs: (value['durationMs'] as num?)?.toInt() ?? 0,
    folder: value['folder'] as String? ?? '',
  );

  static Future<MediaScanEntry> fromFile(String path, {String? name}) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const FileSystemException('文件不存在或无法读取');
    }
    final absolute = p.normalize(p.absolute(path));
    return MediaScanEntry(
      sourceId: Platform.isWindows ? absolute.toLowerCase() : absolute,
      locator: absolute,
      name: name ?? p.basename(path),
      category: mediaCategory(name ?? path) ?? 'audio',
      sizeBytes: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      folder: p.dirname(absolute),
    );
  }
}

class MediaScanBatch {
  const MediaScanBatch({
    required this.entries,
    this.audioAccess = 'full',
    this.videoAccess = 'full',
    this.warnings = const [],
  });

  /// New entries in this batch. Consumers merge by sourceId.
  final List<MediaScanEntry> entries;
  final String audioAccess, videoAccess;
  final List<String> warnings;
}

abstract interface class MediaScanSource {
  Stream<MediaScanBatch> scan({
    List<String> folders = const [],
    required List<String> excludedPaths,
    bool requestPermission = false,
  });
  Future<void> cancel();
  Future<void> copyTo(MediaScanEntry entry, String destination);
}

class MediaScanCancelled implements Exception {
  const MediaScanCancelled();
}

String? mediaCategory(String name) {
  final extension = p.extension(name).toLowerCase();
  if (const {
    '.mp4',
    '.mkv',
    '.mov',
    '.webm',
    '.avi',
    '.m4v',
    '.wmv',
    '.3gp',
    '.3g2',
    '.mpeg',
    '.mpg',
    '.ts',
    '.mts',
    '.m2ts',
    '.flv',
    '.vob',
  }.contains(extension)) {
    return 'video';
  }
  if (const {
    '.mp3',
    '.flac',
    '.wav',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.wma',
    '.aiff',
    '.aif',
    '.alac',
    '.amr',
    '.ape',
    '.ac3',
    '.caf',
    '.m4b',
  }.contains(extension)) {
    return 'audio';
  }
  return null;
}

/// Android uses MediaStore URIs; Windows enumerates known/user-selected folders.
/// Listing never copies media or opens native audio output.
class SystemMediaScanSource implements MediaScanSource {
  SystemMediaScanSource({
    TargetPlatform? targetPlatform,
    MethodChannel? channel,
  }) : _platform = targetPlatform ?? defaultTargetPlatform,
       _channel = channel ?? const MethodChannel('heming_media_scan');

  final TargetPlatform _platform;
  final MethodChannel _channel;
  int _generation = 0;

  @override
  Future<void> cancel() async {
    ++_generation;
    if (_platform == TargetPlatform.android) {
      await Future.wait([
        _channel.invokeMethod<void>('cancelScan').catchError((Object _) {}),
        _channel.invokeMethod<void>('cancelCopy').catchError((Object _) {}),
      ]);
    }
  }

  @override
  Stream<MediaScanBatch> scan({
    List<String> folders = const [],
    required List<String> excludedPaths,
    bool requestPermission = false,
  }) async* {
    final generation = ++_generation;
    if (_platform == TargetPlatform.android) {
      var result = await _channel.invokeMapMethod<String, dynamic>('scan', {
        'requestPermission': requestPermission,
        'excludedPaths': excludedPaths,
      });
      final ids = <String>{};
      while (generation == _generation && result != null) {
        final raw = result['items'] as List? ?? const [];
        final entries = <MediaScanEntry>[];
        for (final value in raw) {
          if (value is! Map) continue;
          final entry = MediaScanEntry.fromMap(value);
          if (entry.sizeBytes > 0 && ids.add(entry.sourceId)) {
            entries.add(entry);
          }
        }
        yield MediaScanBatch(
          entries: entries,
          audioAccess: result['audioAccess'] as String? ?? 'denied',
          videoAccess: result['videoAccess'] as String? ?? 'denied',
          warnings:
              (result['warnings'] as List?)?.whereType<String>().toList() ??
              const [],
        );
        if (generation != _generation || result['hasMore'] != true) return;
        final scanId = result['scanId'];
        if (scanId is! String) throw const FormatException('扫描会话已失效，请重试。');
        result = await _channel.invokeMapMethod<String, dynamic>('scanNext', {
          'scanId': scanId,
        });
      }
      return;
    }
    if (_platform != TargetPlatform.windows) {
      throw UnsupportedError('当前平台尚不支持扫描本机媒体。');
    }
    final roots = [
      ...await _channel.invokeListMethod<String>('defaultFolders') ??
          const <String>[],
      ...folders,
    ];
    if (generation != _generation) return;
    final excludes = excludedPaths.map(_pathKey).toList();
    final visited = <String>{};
    final pending = [...roots];
    final entries = <MediaScanEntry>[];
    final warnings = <String>[];
    bool excluded(String path) {
      final key = _pathKey(path);
      return excludes.any((root) => key == root || p.isWithin(root, key));
    }

    while (pending.isNotEmpty && generation == _generation) {
      final directory = Directory(pending.removeLast());
      final key = _pathKey(directory.path);
      if (!visited.add(key) || excluded(directory.path)) continue;
      try {
        // Never follow junctions/symlinks, including explicitly selected roots.
        if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await for (final entity in directory.list(followLinks: false)) {
          if (generation != _generation) return;
          if (excluded(entity.path)) continue;
          if (entity is Directory) {
            final name = p.basename(entity.path).toLowerCase();
            if (!name.startsWith('.') &&
                !const {
                  r'$recycle.bin',
                  'system volume information',
                  'windows',
                  'program files',
                  'program files (x86)',
                  'programdata',
                  'appdata',
                  'node_modules',
                  'build',
                  'dist',
                }.contains(name)) {
              pending.add(entity.path);
            }
          } else if (entity is File && mediaCategory(entity.path) != null) {
            try {
              final entry = await MediaScanEntry.fromFile(entity.path);
              if (entry.sizeBytes > 0) entries.add(entry);
            } on FileSystemException {
              // A file may disappear between listing and stat; keep the scan.
            }
            if (entries.length >= 100) {
              yield MediaScanBatch(entries: List.of(entries));
              entries.clear();
            }
          }
        }
      } on FileSystemException {
        warnings.add('无法读取文件夹：${directory.path}');
      }
    }
    if (generation != _generation) return;
    yield MediaScanBatch(entries: List.of(entries), warnings: warnings);
  }

  String _pathKey(String path) {
    final value = p.normalize(p.absolute(path));
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  @override
  Future<void> copyTo(MediaScanEntry entry, String destination) async {
    final generation = _generation;
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('目标文件已存在，已取消复制。');
    }
    if (_platform == TargetPlatform.android &&
        entry.locator.startsWith('content://')) {
      await _channel.invokeMethod<void>('copyMedia', {
        'uri': entry.locator,
        'destination': destination,
        'expectedSize': entry.sizeBytes,
        'expectedModifiedMs': entry.modifiedMs,
      });
      if (generation != _generation) throw const MediaScanCancelled();
      return;
    }
    final source = File(entry.locator);
    final before = await source.stat();
    _verifySnapshot(entry, before);
    final output = await File(destination).open(mode: FileMode.writeOnly);
    try {
      await for (final bytes in source.openRead()) {
        if (generation != _generation) throw const MediaScanCancelled();
        await output.writeFrom(bytes);
      }
    } finally {
      await output.close();
    }
    if (generation != _generation) throw const MediaScanCancelled();
    _verifySnapshot(entry, await source.stat());
    if (await File(destination).length() != entry.sizeBytes) {
      throw const FileSystemException('文件内容已变化，请刷新后重新选择。');
    }
  }

  void _verifySnapshot(MediaScanEntry entry, FileStat stat) {
    if (stat.type != FileSystemEntityType.file ||
        stat.size != entry.sizeBytes ||
        stat.modified.millisecondsSinceEpoch != entry.modifiedMs) {
      throw const FileSystemException('文件已变化或无法读取，请刷新后重新选择。');
    }
  }
}

class MediaImportResult {
  const MediaImportResult({
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = false,
    this.failures = const [],
  });
  final int imported, skipped, failed;
  final bool cancelled;
  final List<String> failures;
}
