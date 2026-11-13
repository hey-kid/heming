import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'library_models.dart';
import 'library_repository.dart';
import 'media_scan.dart';

class LibraryController extends ChangeNotifier {
  LibraryController({required this.repository, required this.media});
  final LibraryRepository repository;
  final MediaBackend media;
  final List<LibraryItem> _items = [];
  final List<LibraryGroup> _groups = [];
  final List<String> _conversionQueue = [];
  final Map<String, ConversionToken> _tokens = {};
  final Set<Future<void>> _work = {};
  bool _draining = false, _disposed = false;
  bool _closing = false;
  bool importing = false;
  int importCompleted = 0, importTotal = 0;
  String? importCurrentName;
  bool _importCancelled = false;
  MediaScanSource? _importSource;
  final Set<String> _availableOriginals = {};
  Set<String>? _importedSourceKeys;
  String? message;
  double conversionProgress = 0;
  String? activeConversionId;
  List<LibraryItem> get items => List.unmodifiable(_items);
  List<LibraryGroup> get groups => List.unmodifiable(_groups);
  int get playableCount => _items.where((item) => item.isPlayable).length;

  LibraryGroup? groupById(String id) {
    for (final group in _groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  List<LibraryItem> itemsInGroup(String? groupId) {
    final result = _items.where((item) => item.groupId == groupId).toList();
    if (groupId != null) {
      result.sort((a, b) {
        final order = a.groupOrder.compareTo(b.groupOrder);
        return order != 0 ? order : a.id.compareTo(b.id);
      });
    }
    return List.unmodifiable(result);
  }

  String _groupName(String name, {String? exceptId}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 40) {
      throw const FormatException('分组名称请输入 1–40 个字。');
    }
    if (_groups.any(
      (group) =>
          group.id != exceptId &&
          group.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      throw const FormatException('已经有同名分组，请换一个名称。');
    }
    return trimmed;
  }

  LibraryGroup createGroup(String name) {
    final group = LibraryGroup(
      id: const Uuid().v4(),
      name: _groupName(name),
      sortOrder: _groups.isEmpty ? 0 : _groups.last.sortOrder + 1,
    );
    repository.saveGroup(group);
    _groups.add(group);
    _notify();
    return group;
  }

  void renameGroup(String id, String name) {
    final index = _groups.indexWhere((group) => group.id == id);
    if (index < 0) return;
    final group = _groups[index].copyWith(name: _groupName(name, exceptId: id));
    repository.saveGroup(group);
    _groups[index] = group;
    _notify();
  }

  void deleteGroup(String id) {
    if (groupById(id) == null) return;
    final changed = itemsInGroup(
      id,
    ).map((item) => item.copyWith(clearGroup: true, groupOrder: 0)).toList();
    repository.saveGroupAssignments(changed, deleteGroupId: id);
    _applyGroupAssignments(changed);
    _groups.removeWhere((group) => group.id == id);
    _notify();
  }

  void moveItemsToGroup(Iterable<String> ids, String? groupId) {
    if (groupId != null && groupById(groupId) == null) {
      throw const FormatException('分组已不存在，请重新选择。');
    }
    final members = itemsInGroup(groupId);
    var nextOrder = members.isEmpty ? 0 : members.last.groupOrder + 1;
    final changed = <LibraryItem>[];
    for (final id in ids.toSet()) {
      final item = _byId(id);
      if (item == null || item.groupId == groupId) continue;
      changed.add(
        item.copyWith(
          groupId: groupId,
          clearGroup: groupId == null,
          groupOrder: groupId == null ? 0 : nextOrder++,
        ),
      );
    }
    repository.saveGroupAssignments(changed);
    _applyGroupAssignments(changed);
    _notify();
  }

  void moveItemInGroup(String id, int offset) {
    final item = _byId(id);
    if (item?.groupId == null || offset == 0) return;
    final members = itemsInGroup(item!.groupId).toList();
    final index = members.indexWhere((member) => member.id == id);
    final target = (index + offset).clamp(0, members.length - 1);
    if (target == index) return;
    members.insert(target, members.removeAt(index));
    final changed = [
      for (var index = 0; index < members.length; index++)
        members[index].copyWith(groupOrder: index),
    ];
    repository.saveGroupAssignments(changed);
    _applyGroupAssignments(changed);
    _notify();
  }

  void _applyGroupAssignments(List<LibraryItem> changed) {
    for (final item in changed) {
      final index = _items.indexWhere((current) => current.id == item.id);
      if (index >= 0) _items[index] = item;
    }
  }

  Future<void> initialize() async {
    _groups.addAll(repository.loadGroups());
    _items.addAll(repository.loadItems());
    for (final original in List<LibraryItem>.of(_items)) {
      var item = original;
      if (item.status == LibraryStatus.converting ||
          item.status == LibraryStatus.queued ||
          item.status == LibraryStatus.checking) {
        item = item.copyWith(
          status: LibraryStatus.needsConversion,
          error: '上次处理已中断，可重新检测或转换。',
          clearPlayable: true,
        );
      }
      if (!await File(item.originalPath).exists()) {
        item = item.copyWith(
          status: LibraryStatus.unavailable,
          error: '原文件不可用，请重新导入。',
          clearPlayable: true,
        );
      } else {
        _availableOriginals.add(item.id);
      }
      if (_availableOriginals.contains(item.id) &&
          item.isPlayable &&
          !await File(item.playablePath!).exists()) {
        item = item.copyWith(
          status: LibraryStatus.needsConversion,
          error: '播放副本已丢失，请重新转换。',
          clearPlayable: true,
        );
      }
      if (!identical(item, original)) _replace(item);
    }
    _notify();
  }

  Future<void> importFiles(List<({String path, String name})> files) {
    if (_closing || _disposed) return Future.value();
    return _track(() => _importFiles(files));
  }

  Future<void> _importFiles(List<({String path, String name})> files) async {
    if (importing) return;
    importing = true;
    importCompleted = 0;
    importTotal = files.length;
    _notify();
    var succeeded = 0;
    try {
      for (final source in files) {
        if (_closing || _disposed) break;
        final id = const Uuid().v4();
        final originalName = p.basename(source.name);
        final extension = p.extension(originalName).toLowerCase();
        final destination = p.join(repository.originals.path, '$id$extension');
        try {
          importCurrentName = originalName;
          _notify();
          final snapshot = await MediaScanEntry.fromFile(
            source.path,
            name: source.name,
          );
          // Copy bytes first; neither import nor metadata detection transcodes.
          await File(source.path).copy(destination);
          final originalStat = await File(destination).stat();
          final sourceAfter = await File(source.path).stat();
          final sourceUnchanged =
              sourceAfter.size == snapshot.sizeBytes &&
              sourceAfter.modified.millisecondsSinceEpoch ==
                  snapshot.modifiedMs;
          final digest = await _hashFile(File(destination));
          final item = LibraryItem(
            id: id,
            title: p.basenameWithoutExtension(originalName),
            originalName: originalName,
            originalPath: destination,
            status: LibraryStatus.checking,
            category:
                [
                  '.mp4',
                  '.mkv',
                  '.mov',
                  '.webm',
                  '.avi',
                  '.m4v',
                ].contains(extension)
                ? 'video'
                : 'audio',
            importedAt: DateTime.now(),
            sourceKeys: sourceUnchanged ? [snapshot.sourceKey] : const [],
            contentHash: digest,
            originalSize: originalStat.size,
            originalModifiedMs: originalStat.modified.millisecondsSinceEpoch,
          );
          _items.insert(0, item);
          _availableOriginals.add(item.id);
          repository.save(item);
          _notify();
          await inspectItem(id);
          succeeded++;
        } catch (error) {
          if (!_items.any((item) => item.id == id) &&
              await File(destination).exists()) {
            await File(destination).delete();
          }
          message = '无法导入 $originalName：${_friendly(error)}';
        } finally {
          importCompleted++;
          _notify();
        }
      }
      if (succeeded == files.length) {
        message = '已导入 $succeeded 项，保留原格式；需要转换的资源请点击“转换”。';
      }
    } finally {
      importing = false;
      importCurrentName = null;
      _notify();
    }
  }

  /// An unchanged source already copied into the managed library.
  /// Legacy items acquire source aliases when their content first matches.
  bool isSourceImported(MediaScanEntry entry) => (_importedSourceKeys ??= {
    for (final item in _items)
      if (_availableOriginals.contains(item.id)) ...item.sourceKeys,
  }).contains(entry.sourceKey);

  /// Recheck owned copies before presenting source markers. This makes a source
  /// selectable again if its managed copy was removed outside the application.
  Future<void> refreshAvailableOriginals() {
    if (_closing || _disposed) return Future.value();
    return _track(() async {
      var changed = false;
      for (final item in List<LibraryItem>.of(_items)) {
        if (_closing || _disposed) return;
        final exists = await File(item.originalPath).exists();
        if (_closing || _disposed) return;
        if (_byId(item.id)?.originalPath != item.originalPath) continue;
        changed =
            (exists
                ? _availableOriginals.add(item.id)
                : _availableOriginals.remove(item.id)) ||
            changed;
      }
      if (changed) _notify();
    });
  }

  void cancelImport() {
    _importCancelled = true;
    final source = _importSource;
    if (source != null) unawaited(source.cancel());
  }

  Future<MediaImportResult> importScanned(
    List<MediaScanEntry> entries,
    MediaScanSource source, {
    String? groupId,
  }) async {
    if (_closing || _disposed) return const MediaImportResult(cancelled: true);
    if (importing) throw StateError('正在导入，请稍候。');
    if (groupId != null && groupById(groupId) == null) {
      throw const FormatException('分组已不存在，请重新选择。');
    }
    late MediaImportResult result;
    await _track(() async {
      result = await _importScanned(entries, source, groupId);
    });
    return result;
  }

  bool get _importShouldStop => _importCancelled || _closing || _disposed;

  void _checkImportCancellation() {
    if (_importShouldStop) throw const MediaScanCancelled();
  }

  Future<MediaImportResult> _importScanned(
    List<MediaScanEntry> entries,
    MediaScanSource source,
    String? groupId,
  ) async {
    importing = true;
    _importCancelled = false;
    _importSource = source;
    importTotal = entries.length;
    importCompleted = 0;
    var imported = 0, skipped = 0, failed = 0;
    final failures = <String>[];
    _notify();
    try {
      for (final entry in entries) {
        if (_importShouldStop) break;
        importCurrentName = entry.name;
        _notify();
        final id = const Uuid().v4();
        final name = p.basename(entry.name);
        final extension = p.extension(name).toLowerCase();
        final temporary = File(
          p.join(repository.temporary.path, '$id.import-part'),
        );
        final destination = File(
          p.join(repository.originals.path, '$id$extension'),
        );
        var committed = false;
        try {
          // Never trust a same-name or metadata match as content equality.
          // Re-read selected sources even if a concurrent import just added one.
          await source.copyTo(entry, temporary.path);
          _checkImportCancellation();
          if (await temporary.length() != entry.sizeBytes) {
            throw const FileSystemException('文件大小已变化，请刷新后重试。');
          }
          final hash = await _hashFile(temporary, checkCancellation: true);
          final duplicate = await _findDuplicate(hash, entry.sizeBytes);
          _checkImportCancellation();
          if (duplicate != null) {
            _replace(
              duplicate.copyWith(
                sourceKeys: {...duplicate.sourceKeys, entry.sourceKey}.toList(),
              ),
            );
            skipped++;
            continue;
          }
          if (groupId != null && groupById(groupId) == null) {
            throw const FormatException('目标分组已删除，请重新选择后加入。');
          }
          await temporary.rename(destination.path);
          _checkImportCancellation();
          final stat = await destination.stat();
          _checkImportCancellation();
          final members = groupId == null
              ? const <LibraryItem>[]
              : itemsInGroup(groupId);
          final item = LibraryItem(
            id: id,
            title: p.basenameWithoutExtension(name),
            originalPath: destination.path,
            originalName: name,
            status: LibraryStatus.checking,
            importedAt: DateTime.now(),
            category: entry.category == 'video' ? 'video' : 'audio',
            groupId: groupId,
            groupOrder: members.isEmpty ? 0 : members.last.groupOrder + 1,
            sourceKeys: [entry.sourceKey],
            contentHash: hash,
            originalSize: stat.size,
            originalModifiedMs: stat.modified.millisecondsSinceEpoch,
          );
          repository.save(item);
          _items.insert(0, item);
          _availableOriginals.add(item.id);
          committed = true;
          imported++;
          _notify();
          await inspectItem(id);
        } on MediaScanCancelled {
          _importCancelled = true;
          break;
        } catch (error) {
          if (_importShouldStop) break;
          failed++;
          failures.add('$name：${_friendly(error)}');
        } finally {
          await _deletePartial(temporary);
          if (!committed) await _deletePartial(destination);
          importCompleted = imported + skipped + failed;
          _notify();
        }
      }
      final result = MediaImportResult(
        imported: imported,
        skipped: skipped,
        failed: failed,
        cancelled: _importShouldStop,
        failures: List.unmodifiable(failures),
      );
      message =
          '${result.cancelled ? '已停止加入，' : ''}已加入 $imported 项'
          '${skipped > 0 ? '，跳过 $skipped 项重复资源' : ''}'
          '${failed > 0 ? '，$failed 项未能加入' : ''}。';
      return result;
    } finally {
      importing = false;
      _importSource = null;
      importCurrentName = null;
      _notify();
    }
  }

  Future<String> _hashFile(File file, {bool checkCancellation = false}) async {
    Stream<List<int>> bytes() async* {
      await for (final chunk in file.openRead()) {
        if (checkCancellation) _checkImportCancellation();
        yield chunk;
      }
    }

    return (await sha256.bind(bytes()).first).toString();
  }

  Future<LibraryItem?> _findDuplicate(String hash, int size) async {
    for (final previous in List<LibraryItem>.of(_items)) {
      _checkImportCancellation();
      final file = File(previous.originalPath);
      try {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) {
          _availableOriginals.remove(previous.id);
          continue;
        }
        _availableOriginals.add(previous.id);
        if (stat.size != size) continue;
        var item = _byId(previous.id);
        if (item == null) continue;
        if (item.contentHash == null ||
            item.originalSize != stat.size ||
            item.originalModifiedMs != stat.modified.millisecondsSinceEpoch) {
          final digest = await _hashFile(file, checkCancellation: true);
          final after = await file.stat();
          if (after.size != stat.size || after.modified != stat.modified) {
            continue;
          }
          item = _byId(previous.id);
          if (item == null) continue;
          item = item.copyWith(
            contentHash: digest,
            originalSize: stat.size,
            originalModifiedMs: stat.modified.millisecondsSinceEpoch,
          );
          _replace(item);
        }
        if (item.contentHash == hash) return item;
      } on FileSystemException {
        // An old, unavailable library copy must not prevent a fresh import.
        continue;
      }
    }
    return null;
  }

  Future<void> inspectItem(String id) {
    if (_closing || _disposed) return Future.value();
    return _track(() => _inspectItem(id));
  }

  Future<void> _inspectItem(String id) async {
    final item = _byId(id);
    if (item == null) return;
    _replace(item.copyWith(status: LibraryStatus.checking, clearError: true));
    try {
      var info = await media.inspect(item.originalPath);
      if (info.isCanonical) {
        info = await media.inspect(item.originalPath, verifyDecode: true);
      }
      final ready = info.isCanonical && info.verified;
      _replace(
        item.copyWith(
          metadata: info,
          status: ready ? LibraryStatus.ready : LibraryStatus.needsConversion,
          playablePath: ready ? item.originalPath : null,
          clearPlayable: !ready,
          clearError: true,
        ),
      );
    } catch (error) {
      if (!await File(item.originalPath).exists()) {
        _availableOriginals.remove(item.id);
      }
      _replace(
        item.copyWith(
          status: LibraryStatus.unavailable,
          error: _friendly(error),
          clearPlayable: true,
        ),
      );
    }
  }

  void requestConversion(String id) {
    if (_closing || _disposed) return;
    final item = _byId(id);
    if (item == null || item.isPlayable || _tokens.containsKey(id)) return;
    _tokens[id] = ConversionToken();
    _conversionQueue.add(id);
    _replace(item.copyWith(status: LibraryStatus.queued, clearError: true));
    unawaited(_track(_drain));
  }

  void cancelConversion(String id) {
    _tokens[id]?.cancel();
    if (_conversionQueue.remove(id)) {
      _tokens.remove(id);
      final item = _byId(id);
      if (item != null) {
        _replace(
          item.copyWith(
            status: LibraryStatus.needsConversion,
            error: '已取消转换，原文件已保留。',
          ),
        );
      }
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_conversionQueue.isNotEmpty && !_disposed && !_closing) {
        final id = _conversionQueue.removeAt(0);
        final item = _byId(id);
        final token = _tokens[id];
        if (item == null || token == null) continue;
        final outputName = '$id-${const Uuid().v4()}.flac';
        final temporary = File(p.join(repository.temporary.path, outputName));
        final destination = File(p.join(repository.playable.path, outputName));
        var committed = false;
        activeConversionId = id;
        conversionProgress = 0;
        _replace(
          item.copyWith(status: LibraryStatus.converting, clearError: true),
        );
        try {
          token.throwIfCancelled();
          await media.convert(item.originalPath, temporary.path, token, (
            progress,
          ) {
            conversionProgress = progress.clamp(0, 1);
            _notify();
          });
          token.throwIfCancelled();
          final info = await media.inspect(temporary.path, verifyDecode: true);
          token.throwIfCancelled();
          if (!info.isCanonical || !info.verified) {
            throw const FormatException(
              '转换输出未通过 FLAC / 48 kHz / 16-bit / 双声道校验。',
            );
          }
          await temporary.rename(destination.path);
          token.throwIfCancelled();
          _replace(
            item.copyWith(
              status: LibraryStatus.ready,
              playablePath: destination.path,
              metadata: info,
              clearError: true,
            ),
          );
          committed = true;
          message = '“${item.title}”转换完成，原文件已保留。';
        } on ConversionCancelled {
          _replace(
            item.copyWith(
              status: LibraryStatus.needsConversion,
              error: '已取消转换，原文件已保留。',
              clearPlayable: true,
            ),
          );
        } catch (error) {
          _replace(
            item.copyWith(
              status: token.isCancelled
                  ? LibraryStatus.needsConversion
                  : LibraryStatus.failed,
              error: token.isCancelled ? '已取消转换，原文件已保留。' : _friendly(error),
              clearPlayable: true,
            ),
          );
        } finally {
          // Failed or cancelled output never becomes a valid library artifact.
          await _deletePartial(temporary);
          if (!committed) await _deletePartial(destination);
          _tokens.remove(id);
          activeConversionId = null;
          conversionProgress = 0;
          _notify();
        }
      }
    } catch (error) {
      message = '转换队列已停止：${_friendly(error)}';
      _notify();
    } finally {
      _draining = false;
    }
  }

  Future<bool> validateForPlayback(String id) async {
    final item = _byId(id);
    if (item == null || !item.isPlayable) return false;
    try {
      final file = File(item.playablePath!);
      final handle = await file.open();
      try {
        if (await handle.length() == 0) {
          throw const FileSystemException('播放文件为空');
        }
      } finally {
        await handle.close();
      }
      return true;
    } catch (_) {
      if (!await File(item.originalPath).exists()) {
        _availableOriginals.remove(item.id);
      }
      _replace(
        item.copyWith(
          status: LibraryStatus.unavailable,
          error: '播放文件不可读，请重新检测或转换。',
          clearPlayable: true,
        ),
      );
      return false;
    }
  }

  Future<void> remove(String id) async {
    final item = _byId(id);
    if (item == null || _tokens.containsKey(id)) return;
    // Delete only app-managed copies. A source selected outside our root is never touched.
    for (final candidate in {
      item.originalPath,
      if (item.playablePath != null) item.playablePath!,
    }) {
      if (p.isWithin(repository.root.path, candidate) &&
          await File(candidate).exists()) {
        await File(candidate).delete();
      }
    }
    repository.remove(id);
    _items.removeWhere((value) => value.id == id);
    _availableOriginals.remove(id);
    _notify();
  }

  LibraryItem? _byId(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _replace(LibraryItem item) {
    if (_disposed) return;
    final index = _items.indexWhere((value) => value.id == item.id);
    if (index < 0) return;
    // Inspection/conversion await external work. Preserve any grouping edits
    // made after that work captured its original item snapshot.
    final current = _items[index];
    final merged = item.copyWith(
      groupId: current.groupId,
      clearGroup: current.groupId == null,
      groupOrder: current.groupOrder,
      sourceKeys: {...current.sourceKeys, ...item.sourceKeys}.toList(),
      contentHash: item.contentHash ?? current.contentHash,
      originalSize: item.originalSize ?? current.originalSize,
      originalModifiedMs: item.originalModifiedMs ?? current.originalModifiedMs,
    );
    _items[index] = merged;
    repository.save(merged);
    _notify();
  }

  void _notify() {
    _importedSourceKeys = null;
    if (!_disposed) notifyListeners();
  }

  static String _friendly(Object error) => error.toString().replaceFirst(
    RegExp(r'^(Exception|AudioException|FormatException):\s*'),
    '',
  );

  Future<void> _track(Future<void> Function() operation) async {
    final future = operation();
    _work.add(future);
    try {
      await future;
    } finally {
      _work.remove(future);
    }
  }

  Future<void> _deletePartial(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      message = '部分临时文件暂时无法清理，可在退出应用后清理应用临时目录。';
    }
  }

  /// Wait for workers before closing SQLite or platform channels.
  Future<void> close() async {
    _closing = true;
    cancelImport();
    for (final token in _tokens.values.toList()) {
      token.cancel();
    }
    while (_work.isNotEmpty) {
      await Future.wait(
        _work.toList().map((work) => work.catchError((Object _) {})),
      );
    }
    if (!_disposed) dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelImport();
    for (final token in _tokens.values) {
      token.cancel();
    }
    super.dispose();
  }
}
