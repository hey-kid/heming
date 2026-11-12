import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'library_models.dart';
import 'library_repository.dart';

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
      } else if (item.isPlayable && !await File(item.playablePath!).exists()) {
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
          // Copy bytes first; neither import nor metadata detection transcodes.
          await File(source.path).copy(destination);
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
          );
          _items.insert(0, item);
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
        }
      }
      if (succeeded == files.length) {
        message = '已导入 $succeeded 项，保留原格式；需要转换的资源请点击“转换”。';
      }
    } finally {
      importing = false;
      _notify();
    }
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
    );
    _items[index] = merged;
    repository.save(merged);
    _notify();
  }

  void _notify() {
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
    for (final token in _tokens.values) {
      token.cancel();
    }
    super.dispose();
  }
}
