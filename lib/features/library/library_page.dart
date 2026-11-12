import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../app/components.dart';
import '../../app/desktop_components.dart';
import '../../app/mobile_components.dart';
import '../../data/library_controller.dart';
import '../../data/library_models.dart';
import '../../preview/preview_controller.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.library,
    required this.canPlay,
    required this.onPlay,
    required this.onPlaylist,
    this.preview,
    this.canPreview = false,
  });
  final LibraryController library;
  final bool canPlay;
  final Future<void> Function(LibraryItem) onPlay;
  final Future<void> Function(List<LibraryItem>) onPlaylist;
  final PreviewController? preview;
  final bool canPreview;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _filter = 'all';
  String _search = '';
  String _groupFilter = 'all';
  bool _selecting = false;
  final Set<String> _selected = {};

  void _changeFilters(VoidCallback change) {
    setState(change);
    reportAction(context, _stopHiddenPreview);
  }

  Future<void> _stopHiddenPreview() async {
    final preview = widget.preview;
    if (preview?.itemId == null) return;
    final visible = widget.library.items.any(
      (item) =>
          item.id == preview!.itemId &&
          (_groupFilter == 'all' ||
              (_groupFilter == 'ungrouped'
                  ? item.groupId == null
                  : item.groupId == _groupFilter)) &&
          (_filter == 'all' || item.category == _filter) &&
          item.title.toLowerCase().contains(_search.toLowerCase()),
    );
    if (!visible) await preview!.stop();
  }

  Future<void> _editGroup([LibraryGroup? group]) async {
    var name = group?.name ?? '';
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(group == null ? '新建分组' : '重命名分组'),
          content: TextFormField(
            initialValue: name,
            onChanged: (value) => name = value,
            autofocus: true,
            maxLength: 40,
            decoration: InputDecoration(labelText: '分组名称', errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final id = group == null
                      ? widget.library.createGroup(name).id
                      : group.id;
                  if (group != null) widget.library.renameGroup(group.id, name);
                  Navigator.pop(context, id);
                } on FormatException catch (failure) {
                  refresh(() => error = failure.message);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      _changeFilters(() {
        _groupFilter = result;
        _selected.clear();
      });
    }
  }

  Future<void> _deleteGroup(LibraryGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${group.name}”？'),
        content: const Text('组内资源会移到“未分组”，音频文件会保留。已经开始的播放列表不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除分组'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.library.deleteGroup(group.id);
    _changeFilters(() => _groupFilter = 'ungrouped');
  }

  Future<void> _moveItems(Iterable<String> ids) async {
    final selected = ids.toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('将 ${selected.length} 项移入分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'ungrouped'),
            child: const Text('未分组'),
          ),
          for (final group in widget.library.groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, group.id),
              child: Text(group.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    widget.library.moveItemsToGroup(
      selected,
      target == 'ungrouped' ? null : target,
    );
    setState(_selected.clear);
    await _stopHiddenPreview();
  }

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      dialogTitle: '导入音频或视频，原文件保持不变',
    );
    if (result.isEmpty) return;
    final paths = result
        .where((file) => file.path != null)
        .map((file) => (path: file.path!, name: file.name))
        .toList();
    if (paths.length != result.length && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('部分文件无法读取，请选择已下载到设备的文件。')));
    }
    await widget.library.importFiles(paths);
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final group = library.groupById(_groupFilter);
    final groupItems = _groupFilter == 'all'
        ? library.items
        : library.itemsInGroup(group?.id);
    final visible = groupItems
        .where(
          (item) =>
              (_filter == 'all' || item.category == _filter) &&
              item.title.toLowerCase().contains(_search.toLowerCase()),
        )
        .toList();
    if (isMobileLayout(context)) {
      return _buildMobile(context, group, groupItems, visible);
    }
    return _buildDesktop(context, group, groupItems, visible);
  }

  Widget _buildDesktop(
    BuildContext context,
    LibraryGroup? group,
    List<LibraryItem> groupItems,
    List<LibraryItem> visible,
  ) {
    final library = widget.library;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeading(
          title: '资源库',
          subtitle: '',
          action: FilledButton.icon(
            onPressed: library.importing
                ? null
                : () => reportAction(context, _import),
            icon: library.importing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add, size: 18),
            label: Text(library.importing ? '正在导入' : '导入资源'),
          ),
        ),
        const SizedBox(height: 24),
        DesktopSection(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(_groupFilter),
                      initialValue:
                          group?.id ??
                          (_groupFilter == 'all' ? 'all' : 'ungrouped'),
                      isExpanded: true,
                      decoration: const InputDecoration(
                        hintText: '资源分组',
                        prefixIcon: Icon(Icons.folder_outlined, size: 19),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'all',
                          child: Text('全部资源'),
                        ),
                        const DropdownMenuItem(
                          value: 'ungrouped',
                          child: Text('未分组'),
                        ),
                        for (final entry in library.groups)
                          DropdownMenuItem(
                            value: entry.id,
                            child: Text(
                              entry.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _changeFilters(() {
                            _groupFilter = value;
                            _selected.clear();
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    tooltip: '分组操作',
                    icon: const Icon(Icons.more_horiz, size: 21),
                    onSelected: (value) => reportAction(context, () async {
                      if (value == 'create') await _editGroup();
                      if (value == 'rename' && group != null) {
                        await _editGroup(group);
                      }
                      if (value == 'delete' && group != null) {
                        await _deleteGroup(group);
                      }
                    }),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'create', child: Text('新建分组')),
                      if (group != null) ...[
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('重命名分组'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('删除分组'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      onChanged: (value) =>
                          _changeFilters(() => _search = value),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: '搜索本机资源',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'all', label: Text('全部')),
                        ButtonSegment(value: 'audio', label: Text('音频')),
                        ButtonSegment(value: 'video', label: Text('视频')),
                      ],
                      selected: {_filter},
                      onSelectionChanged: (value) =>
                          _changeFilters(() => _filter = value.first),
                      style: SegmentedButton.styleFrom(
                        minimumSize: const Size(64, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        side: BorderSide.none,
                        backgroundColor: colors.surfaceContainerLow,
                        selectedBackgroundColor: colors.primaryContainer,
                        selectedForegroundColor: colors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(11),
                        ),
                      ),
                    ),
                    if (widget.canPlay)
                      DesktopActionButton(
                        label: group == null ? '播放此列表' : '播放本组',
                        icon: Icons.playlist_play,
                        primary: true,
                        onPressed:
                            (group == null ? visible : groupItems).isEmpty
                            ? null
                            : () => reportAction(
                                context,
                                () => widget.onPlaylist(
                                  group == null ? visible : groupItems,
                                ),
                              ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          widget.canPreview ? '本机试听' : '由主控选择播放',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        DesktopSection(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${visible.length} 项资源',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: library.items.isEmpty
                          ? null
                          : () => setState(() {
                              _selecting = !_selecting;
                              _selected.clear();
                            }),
                      icon: Icon(
                        _selecting ? Icons.close : Icons.checklist,
                        size: 18,
                      ),
                      label: Text(_selecting ? '完成管理' : '批量管理'),
                    ),
                  ],
                ),
              ),
              if (_selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '已选 ${_selected.length} 项',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () =>
                              _selected.addAll(visible.map((item) => item.id)),
                        ),
                        child: const Text('全选当前列表'),
                      ),
                      DesktopActionButton(
                        label: '移动 ${_selected.length} 项',
                        icon: Icons.drive_file_move_outline,
                        onPressed: _selected.isEmpty
                            ? null
                            : () => reportAction(
                                context,
                                () => _moveItems(_selected),
                              ),
                      ),
                    ],
                  ),
                ),
              const Divider(),
              if (library.items.isEmpty)
                EmptyPanel(
                  icon: Icons.library_music_outlined,
                  title: '收藏你的第一段声音',
                  description: '导入音频或视频，原文件保持不变。',
                  action: DesktopActionButton(
                    label: '导入第一项资源',
                    icon: Icons.add,
                    onPressed: library.importing
                        ? null
                        : () => reportAction(context, _import),
                  ),
                )
              else if (visible.isEmpty)
                const EmptyPanel(
                  icon: Icons.search_off,
                  title: '没有匹配的资源',
                  description: '换一个分组、分类或搜索词试试。',
                )
              else ...[
                const _DesktopLibraryColumns(),
                for (var index = 0; index < visible.length; index++) ...[
                  if (index > 0) const Divider(indent: 20, endIndent: 20),
                  _LibraryRow(
                    key: ValueKey(visible[index].id),
                    item: visible[index],
                    controller: library,
                    canPlay: widget.canPlay,
                    onPlay: () => widget.onPlay(visible[index]),
                    preview: widget.preview,
                    canPreview: widget.canPreview,
                    selected: _selecting
                        ? _selected.contains(visible[index].id)
                        : null,
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selected.add(visible[index].id);
                      } else {
                        _selected.remove(visible[index].id);
                      }
                    }),
                    onMove: () => _moveItems([visible[index].id]),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobile(
    BuildContext context,
    LibraryGroup? group,
    List<LibraryItem> groupItems,
    List<LibraryItem> visible,
  ) {
    final library = widget.library;
    final colors = Theme.of(context).colorScheme;
    final count = visible.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '资源库',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            FilledButton.icon(
              onPressed: library.importing
                  ? null
                  : () => reportAction(context, _import),
              icon: library.importing
                  ? const SizedBox.square(
                      dimension: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add, size: 20),
              label: Text(library.importing ? '导入中' : '导入'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (library.items.length > 5) ...[
          TextField(
            onChanged: (value) => _changeFilters(() => _search = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, size: 21),
              hintText: '搜索资源',
            ),
          ),
          const SizedBox(height: 14),
        ],
        MobileSection(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 21, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(_groupFilter),
                  initialValue:
                      group?.id ??
                      (_groupFilter == 'all' ? 'all' : 'ungrouped'),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    hintText: '资源分组',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: 'all', child: Text('全部资源')),
                    const DropdownMenuItem(
                      value: 'ungrouped',
                      child: Text('未分组'),
                    ),
                    for (final entry in library.groups)
                      DropdownMenuItem(
                        value: entry.id,
                        child: Text(
                          entry.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      _changeFilters(() {
                        _groupFilter = value;
                        _selected.clear();
                      });
                    }
                  },
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '分组操作',
                icon: const Icon(Icons.more_horiz),
                onSelected: (value) => reportAction(context, () async {
                  if (value == 'create') await _editGroup();
                  if (value == 'rename' && group != null) {
                    await _editGroup(group);
                  }
                  if (value == 'delete' && group != null) {
                    await _deleteGroup(group);
                  }
                }),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'create', child: Text('新建分组')),
                  if (group != null) ...[
                    const PopupMenuItem(value: 'rename', child: Text('重命名分组')),
                    const PopupMenuItem(value: 'delete', child: Text('删除分组')),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'all', label: Text('全部')),
              ButtonSegment(value: 'audio', label: Text('音频')),
              ButtonSegment(value: 'video', label: Text('视频')),
            ],
            selected: {_filter},
            onSelectionChanged: (selection) =>
                _changeFilters(() => _filter = selection.first),
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              side: BorderSide.none,
              backgroundColor: colors.surfaceContainerHighest,
              selectedBackgroundColor: colors.surfaceContainerLowest,
              selectedForegroundColor: colors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        if (widget.canPlay) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: MobileActionButton(
              label: group == null ? '播放此列表' : '播放本组',
              icon: Icons.play_arrow_rounded,
              primary: true,
              onPressed: (group == null ? visible : groupItems).isEmpty
                  ? null
                  : () => reportAction(
                      context,
                      () => widget.onPlaylist(
                        group == null ? visible : groupItems,
                      ),
                    ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        MobileSectionHeader(
          title: '$count 项资源',
          trailing: TextButton(
            onPressed: library.items.isEmpty
                ? null
                : () => setState(() {
                    _selecting = !_selecting;
                    _selected.clear();
                  }),
            child: Text(_selecting ? '完成管理' : '批量管理'),
          ),
        ),
        if (_selecting) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _selected.addAll(visible.map((item) => item.id)),
                  ),
                  child: const Text('全选当前列表'),
                ),
                OutlinedButton.icon(
                  onPressed: _selected.isEmpty
                      ? null
                      : () =>
                            reportAction(context, () => _moveItems(_selected)),
                  icon: const Icon(Icons.drive_file_move_outline, size: 18),
                  label: Text('移动 ${_selected.length} 项'),
                ),
              ],
            ),
          ),
        ],
        MobileSection(
          padding: EdgeInsets.zero,
          child: library.items.isEmpty
              ? const EmptyPanel(
                  icon: Icons.library_music_outlined,
                  title: '收藏你的第一段声音',
                  description: '轻点右上角，导入音频或视频。',
                )
              : visible.isEmpty
              ? const EmptyPanel(
                  icon: Icons.search_off,
                  title: '没有匹配的资源',
                  description: '换一个分类或搜索词试试。',
                )
              : Column(
                  children: [
                    for (var index = 0; index < visible.length; index++) ...[
                      if (index > 0) const Divider(indent: 68, endIndent: 16),
                      _LibraryRow(
                        key: ValueKey(visible[index].id),
                        item: visible[index],
                        controller: library,
                        canPlay: widget.canPlay,
                        onPlay: () => widget.onPlay(visible[index]),
                        preview: widget.preview,
                        canPreview: widget.canPreview,
                        selected: _selecting
                            ? _selected.contains(visible[index].id)
                            : null,
                        onSelected: (value) => setState(() {
                          if (value) {
                            _selected.add(visible[index].id);
                          } else {
                            _selected.remove(visible[index].id);
                          }
                        }),
                        onMove: () => _moveItems([visible[index].id]),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _DesktopLibraryColumns extends StatelessWidget {
  const _DesktopLibraryColumns();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth < 840 ||
          MediaQuery.textScalerOf(context).scale(14) > 18.2) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(68, 13, 20, 5),
        child: DefaultTextStyle(
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          child: const Row(
            children: [
              Expanded(child: Text('名称')),
              SizedBox(width: 12),
              SizedBox(width: 64, child: Text('时长')),
              SizedBox(width: 12),
              SizedBox(width: 86, child: Text('状态')),
              SizedBox(width: 12),
              SizedBox(
                width: 208,
                child: Text('操作', textAlign: TextAlign.right),
              ),
              SizedBox(width: 44),
            ],
          ),
        ),
      );
    },
  );
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({
    super.key,
    required this.item,
    required this.controller,
    required this.canPlay,
    required this.onPlay,
    required this.selected,
    required this.onSelected,
    required this.onMove,
    required this.preview,
    required this.canPreview,
  });
  final LibraryItem item;
  final LibraryController controller;
  final bool canPlay;
  final Future<void> Function() onPlay;
  final bool? selected;
  final ValueChanged<bool> onSelected;
  final Future<void> Function() onMove;
  final PreviewController? preview;
  final bool canPreview;
  String get status => switch (item.status) {
    LibraryStatus.checking => '检测中',
    LibraryStatus.needsConversion => '待转换',
    LibraryStatus.queued => '等待转换',
    LibraryStatus.converting => '转换中',
    LibraryStatus.ready => '可播放',
    LibraryStatus.failed => '转换失败',
    LibraryStatus.unavailable => '不可用',
  };

  Future<void> _remove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出资源库？'),
        content: Text('移除“${item.title}”及应用内的播放副本。你最初选择的源文件保持不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (preview?.itemId == item.id) await preview!.stop();
      await controller.remove(item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = [
      LibraryStatus.checking,
      LibraryStatus.queued,
      LibraryStatus.converting,
    ].contains(item.status);
    final info = item.metadata;
    final profile = info == null
        ? item.originalName
        : '${info.codec.toUpperCase()} · ${(info.sampleRate / 1000).toStringAsFixed(info.sampleRate % 1000 == 0 ? 0 : 1)} kHz${info.bitsPerSample > 0 ? ' · ${info.bitsPerSample}-bit' : ''} · ${info.channels == 2 ? '双声道' : '${info.channels} 声道'}';
    final action = switch (item.status) {
      LibraryStatus.ready => OutlinedButton.icon(
        onPressed: canPlay ? () => reportAction(context, onPlay) : null,
        icon: const Icon(Icons.play_arrow_outlined, size: 19),
        label: const Text('播放'),
      ),
      LibraryStatus.checking => const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      LibraryStatus.queued || LibraryStatus.converting => TextButton(
        onPressed: () => controller.cancelConversion(item.id),
        child: const Text('取消'),
      ),
      LibraryStatus.unavailable => OutlinedButton(
        onPressed: () =>
            reportAction(context, () => controller.inspectItem(item.id)),
        child: const Text('重新检测'),
      ),
      LibraryStatus.failed || LibraryStatus.needsConversion => OutlinedButton(
        onPressed: () => controller.requestConversion(item.id),
        child: Text(item.status == LibraryStatus.failed ? '重试转换' : '转换'),
      ),
    };
    final actions = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!canPreview ||
            preview == null ||
            item.status != LibraryStatus.ready)
          action,
        if (canPreview && preview != null)
          _PreviewButton(item: item, preview: preview!),
      ],
    );
    if (isMobileLayout(context)) {
      return _buildMobile(context, busy, profile, actions);
    }
    return _buildDesktop(context, busy, profile, actions);
  }

  Widget _buildDesktop(
    BuildContext context,
    bool busy,
    String profile,
    Widget actions,
  ) {
    final colors = Theme.of(context).colorScheme;
    final groupName = item.groupId == null
        ? null
        : controller.groupById(item.groupId!)?.name;
    return LayoutBuilder(
      builder: (context, box) {
        final columns =
            box.maxWidth >= 840 &&
            MediaQuery.textScalerOf(context).scale(14) <= 18.2;
        final summary = [
          if (!columns && item.durationMs > 0) formatDuration(item.durationMs),
          if (!columns) status,
          ?groupName,
          if (item.metadata != null) item.metadata!.codec.toUpperCase(),
        ].join(' · ');
        final actionWidth = columns || box.maxWidth >= 660 ? 208.0 : 180.0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 40,
                    child: selected != null
                        ? Checkbox(
                            value: selected,
                            visualDensity: VisualDensity.compact,
                            onChanged: (value) => onSelected(value == true),
                          )
                        : Center(
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: item.isPlayable
                                    ? colors.primaryContainer.withValues(
                                        alpha: 0.6,
                                      )
                                    : colors.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                item.category == 'video'
                                    ? Icons.movie_outlined
                                    : Icons.music_note_rounded,
                                color: colors.primary,
                                size: 20,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontSize: 14, height: 1.4),
                        ),
                        if (summary.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (columns) ...[
                    SizedBox(
                      width: 64,
                      child: Text(
                        item.durationMs > 0
                            ? formatDuration(item.durationMs)
                            : '—',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 86,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: StatusBadge(status, warning: !item.isPlayable),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  SizedBox(
                    width: actionWidth,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButtonTheme(
                        data: OutlinedButtonThemeData(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            backgroundColor: colors.surfaceContainerLow,
                            foregroundColor: colors.primary,
                            side: BorderSide.none,
                            textStyle: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        child: actions,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 40,
                    child: _desktopMenu(context, busy, profile),
                  ),
                ],
              ),
              if (item.error != null)
                Padding(
                  padding: const EdgeInsets.only(left: 48, right: 44, top: 8),
                  child: Text(
                    item.error!,
                    style: TextStyle(fontSize: 12, color: colors.error),
                  ),
                ),
              if (item.status == LibraryStatus.converting)
                Padding(
                  padding: const EdgeInsets.only(left: 48, right: 44, top: 10),
                  child: LinearProgressIndicator(
                    value: controller.conversionProgress > 0
                        ? controller.conversionProgress
                        : null,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              if (canPreview && preview != null)
                Padding(
                  padding: const EdgeInsets.only(left: 48, right: 44),
                  child: _PreviewStrip(item: item, preview: preview!),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _desktopMenu(
    BuildContext context,
    bool busy,
    String profile,
  ) => PopupMenuButton<String>(
    tooltip: '资源操作',
    icon: const Icon(Icons.more_horiz, size: 20),
    onSelected: (value) {
      if (value == 'move') reportAction(context, onMove);
      if (value == 'up') controller.moveItemInGroup(item.id, -1);
      if (value == 'down') controller.moveItemInGroup(item.id, 1);
      if (value == 'remove') reportAction(context, () => _remove(context));
      if (value == 'details') {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(item.title),
            content: SingleChildScrollView(
              child: SelectableText(
                '原件：${item.originalName}\n\n$profile\n\n${item.originalPath}${item.playablePath != null && item.playablePath != item.originalPath ? '\n\n播放副本：${item.playablePath}' : ''}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'move', child: Text('移入分组')),
      if (item.groupId != null) ...[
        PopupMenuItem(
          value: 'up',
          enabled: controller.itemsInGroup(item.groupId).first.id != item.id,
          child: const Text('在组内上移'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: controller.itemsInGroup(item.groupId).last.id != item.id,
          child: const Text('在组内下移'),
        ),
      ],
      const PopupMenuItem(value: 'details', child: Text('资源详情')),
      PopupMenuItem(
        value: 'remove',
        enabled: !busy,
        child: const Text('移出资源库'),
      ),
    ],
  );

  Widget _buildMobile(
    BuildContext context,
    bool busy,
    String profile,
    Widget actions,
  ) {
    final colors = Theme.of(context).colorScheme;
    final groupName = item.groupId == null
        ? null
        : controller.groupById(item.groupId!)?.name;
    final details = [
      if (item.durationMs > 0) formatDuration(item.durationMs),
      ?groupName,
      if (!item.isPlayable) status,
    ].join(' · ');
    final compactReadyActions =
        item.status == LibraryStatus.ready && (canPlay || canPreview);
    final styledActions = OutlinedButtonTheme(
      data: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          side: BorderSide.none,
          backgroundColor: colors.surfaceContainerLow,
          foregroundColor: colors.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      child: actions,
    );
    return Padding(
      padding: compactReadyActions
          ? const EdgeInsets.fromLTRB(16, 12, 8, 12)
          : const EdgeInsets.fromLTRB(16, 16, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selected != null)
                Checkbox(
                  value: selected,
                  onChanged: (value) => onSelected(value == true),
                  visualDensity: VisualDensity.compact,
                )
              else
                Container(
                  width: 40,
                  height: 44,
                  decoration: BoxDecoration(
                    color: item.isPlayable
                        ? colors.primaryContainer.withValues(alpha: 0.55)
                        : colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    item.category == 'video'
                        ? Icons.movie_outlined
                        : Icons.music_note_rounded,
                    color: colors.primary,
                    size: 22,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (details.isNotEmpty && !compactReadyActions) ...[
                      const SizedBox(height: 5),
                      Text(
                        details,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                          height: 1.35,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              _mobileMenu(context, busy, profile),
            ],
          ),
          if (item.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10, right: 8),
              child: Text(
                item.error!,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            ),
          if (compactReadyActions)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: LayoutBuilder(
                builder: (context, box) {
                  // Keep metadata under the title on regular phones. On
                  // narrow screens or with larger text, use the full width
                  // while preserving the action's label and touch target.
                  final inset =
                      box.maxWidth >= 280 &&
                          MediaQuery.textScalerOf(context).scale(14) <= 18.2
                      ? 52.0
                      : 0.0;
                  return Padding(
                    padding: EdgeInsets.only(left: inset),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            details,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 13,
                              height: 1.35,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        styledActions,
                      ],
                    ),
                  );
                },
              ),
            )
          else if (item.status != LibraryStatus.ready || canPlay || canPreview)
            Padding(
              padding: const EdgeInsets.only(top: 10, right: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: styledActions,
              ),
            ),
          if (item.status == LibraryStatus.converting)
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 8),
              child: LinearProgressIndicator(
                value: controller.conversionProgress > 0
                    ? controller.conversionProgress
                    : null,
                minHeight: 3,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          if (canPreview && preview != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _PreviewStrip(item: item, preview: preview!),
            ),
        ],
      ),
    );
  }

  Widget _mobileMenu(
    BuildContext context,
    bool busy,
    String profile,
  ) => PopupMenuButton<String>(
    tooltip: '资源操作',
    icon: const Icon(Icons.more_horiz, size: 21),
    onSelected: (value) {
      if (value == 'move') reportAction(context, onMove);
      if (value == 'up') controller.moveItemInGroup(item.id, -1);
      if (value == 'down') controller.moveItemInGroup(item.id, 1);
      if (value == 'remove') reportAction(context, () => _remove(context));
      if (value == 'details') {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(item.title),
            content: SelectableText(
              '原件：${item.originalName}\n\n$profile\n\n${item.originalPath}${item.playablePath != null && item.playablePath != item.originalPath ? '\n\n播放副本：${item.playablePath}' : ''}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'move', child: Text('移入分组')),
      if (item.groupId != null) ...[
        PopupMenuItem(
          value: 'up',
          enabled: controller.itemsInGroup(item.groupId).first.id != item.id,
          child: const Text('在组内上移'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: controller.itemsInGroup(item.groupId).last.id != item.id,
          child: const Text('在组内下移'),
        ),
      ],
      const PopupMenuItem(value: 'details', child: Text('资源详情')),
      PopupMenuItem(
        value: 'remove',
        enabled: !busy,
        child: const Text('移出资源库'),
      ),
    ],
  );
}

class _PreviewButton extends StatelessWidget {
  const _PreviewButton({required this.item, required this.preview});
  final LibraryItem item;
  final PreviewController preview;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preview,
    builder: (context, _) {
      final current = preview.itemId == item.id;
      final playing = current && preview.state == PreviewState.playing;
      final loading = current && preview.state == PreviewState.loading;
      return OutlinedButton.icon(
        onPressed: item.status == LibraryStatus.unavailable || loading
            ? null
            : () => reportAction(
                context,
                () =>
                    current &&
                        (preview.state == PreviewState.playing ||
                            preview.state == PreviewState.paused)
                    ? preview.togglePause()
                    : preview.play(item),
              ),
        icon: loading
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(playing ? Icons.pause : Icons.headphones_outlined, size: 18),
        label: Text(
          loading
              ? '正在载入'
              : playing
              ? '暂停试听'
              : current && preview.state == PreviewState.paused
              ? '继续试听'
              : '试听',
        ),
      );
    },
  );
}

class _PreviewStrip extends StatefulWidget {
  const _PreviewStrip({required this.item, required this.preview});
  final LibraryItem item;
  final PreviewController preview;

  @override
  State<_PreviewStrip> createState() => _PreviewStripState();
}

class _PreviewStripState extends State<_PreviewStrip> {
  double? _seekPosition;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.preview,
    builder: (context, _) {
      final preview = widget.preview;
      if (preview.itemId != widget.item.id) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      final duration = preview.durationMs > 0
          ? preview.durationMs
          : widget.item.durationMs;
      final position = (_seekPosition ?? preview.positionMs.toDouble())
          .clamp(0, duration > 0 ? duration : 0)
          .toDouble();
      final loading = preview.state == PreviewState.loading;
      final restart =
          preview.state == PreviewState.completed ||
          preview.state == PreviewState.failed;
      return Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: restart
                      ? '重新试听'
                      : preview.state == PreviewState.playing
                      ? '暂停试听'
                      : '继续试听',
                  onPressed: loading
                      ? null
                      : () => reportAction(
                          context,
                          () => restart
                              ? preview.play(widget.item)
                              : preview.togglePause(),
                        ),
                  icon: Icon(
                    restart
                        ? Icons.replay
                        : preview.state == PreviewState.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
                Expanded(
                  child: Text(
                    loading
                        ? '正在载入试听…'
                        : '本机试听 · ${formatDuration(position.round())} / ${formatDuration(duration)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: '结束试听',
                  onPressed: () => reportAction(context, preview.stop),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
            if (preview.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  preview.error!,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            if (preview.state != PreviewState.failed)
              Slider(
                value: position,
                max: duration > 0 ? duration.toDouble() : 1,
                semanticFormatterCallback: (value) =>
                    formatDuration(value.round()),
                onChanged: loading || duration <= 0
                    ? null
                    : (value) => setState(() => _seekPosition = value),
                onChangeEnd: (value) {
                  setState(() => _seekPosition = null);
                  reportAction(context, () => preview.seek(value.round()));
                },
              ),
          ],
        ),
      );
    },
  );
}
