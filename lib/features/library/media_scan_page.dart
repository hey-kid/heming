import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/library_controller.dart';
import '../../data/media_scan.dart';
import '../../data/media_source_actions.dart';
import '../../preview/preview_controller.dart';
import '../../preview/scan_preview_controller.dart';
import 'scan_preview_strip.dart';

/// A candidate list: discovery never copies files or changes the library.
class MediaScanPage extends StatefulWidget {
  const MediaScanPage({
    super.key,
    required this.library,
    this.source,
    this.initialGroupId,
    this.android,
    this.preview,
    this.canPreview = false,
    this.scanPreview,
    this.sourceActions,
  });

  final LibraryController library;
  final MediaScanSource? source;
  final String? initialGroupId;
  final bool? android;
  final PreviewController? preview;
  final bool canPreview;
  final ScanPreviewController? scanPreview;
  final MediaSourceActions? sourceActions;

  @override
  State<MediaScanPage> createState() => _MediaScanPageState();
}

class _MediaScanPageState extends State<MediaScanPage>
    with WidgetsBindingObserver {
  late final MediaScanSource _source = widget.source ?? SystemMediaScanSource();
  late final bool _android = widget.android ?? Platform.isAndroid;
  late final ScanPreviewController? _preview =
      widget.scanPreview ??
      (widget.preview == null
          ? null
          : ScanPreviewController(player: widget.preview!));
  late final MediaSourceActions _sourceActions =
      widget.sourceActions ?? MediaSourceActions();
  Object? _previewDisplay;
  final _entries = <String, MediaScanEntry>{};
  final _selected = <String>{};
  final _folders = <String>[];
  String _category = 'all', _search = '', _sort = 'name';
  String? _groupId;
  String _audioAccess = 'full', _videoAccess = 'full';
  String? _error, _summary;
  List<String> _warnings = [];
  bool _scanning = false, _adding = false, _allowPop = false;
  bool _closing = false;
  bool _stopAdding = false;
  bool _resumeRefreshPending = false;
  bool _foreground = true;
  int _sourceActionRevision = 0;
  int _generation = 0;
  Future<void>? _importFuture;

  @override
  void initState() {
    super.initState();
    _groupId = widget.initialGroupId;
    _preview?.addListener(_onPreviewChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scan(requestPermission: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) {
      ++_sourceActionRevision;
      unawaited(_preview?.stop());
    }
    if (mounted) setState(() {});
    // Android permissions may be narrowed while this page is backgrounded.
    if (_android && state == AppLifecycleState.resumed && !_closing) {
      if (_scanning || _adding) {
        _resumeRefreshPending = true;
      } else {
        unawaited(_scan());
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    ++_sourceActionRevision;
    WidgetsBinding.instance.removeObserver(this);
    _preview?.removeListener(_onPreviewChanged);
    if (widget.scanPreview == null) {
      unawaited(_preview?.close());
    } else {
      unawaited(_preview?.stop());
    }
    unawaited(_source.cancel());
    if (_adding) widget.library.cancelImport();
    super.dispose();
  }

  bool get _canPreview =>
      widget.canPreview &&
      (_preview?.allowed ?? false) &&
      _foreground &&
      !_adding &&
      !_closing;

  bool get _canOpenExternally =>
      widget.canPreview &&
      (_preview?.allowed ?? true) &&
      _foreground &&
      !_adding &&
      !_closing;

  void _onPreviewChanged() {
    final next = (
      _preview?.entry?.sourceId,
      _preview?.state,
      _preview?.error,
      _preview?.allowed,
    );
    if (mounted && _previewDisplay != next) {
      setState(() => _previewDisplay = next);
    }
  }

  Future<void> _playPreview(MediaScanEntry entry) async {
    if (!_canPreview || entry.category != 'audio') return;
    final preview = _preview!;
    try {
      if (preview.entry?.sourceId == entry.sourceId &&
          (preview.state == PreviewState.playing ||
              preview.state == PreviewState.paused)) {
        await preview.togglePause();
      } else {
        await preview.play(entry);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    }
  }

  Future<void> _sourceAction(MediaScanEntry entry, String action) async {
    if (_adding ||
        _closing ||
        !_foreground ||
        (action == 'open' && !_canOpenExternally)) {
      return;
    }
    final revision = ++_sourceActionRevision;
    try {
      await _preview?.stop();
      if (!mounted ||
          _closing ||
          !_foreground ||
          revision != _sourceActionRevision ||
          (action == 'open' && !_canOpenExternally)) {
        return;
      }
      if (action == 'open') {
        await _sourceActions.open(entry);
      } else {
        await _sourceActions.reveal(entry);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendly(error))));
    }
  }

  Future<void> _scan({bool requestPermission = false}) async {
    if (_adding || _closing) return;
    final generation = ++_generation;
    setState(() {
      _scanning = true;
      _error = null;
      _summary = null;
      _warnings = [];
      _entries.clear();
    });
    try {
      await _source.cancel();
      if (!mounted || generation != _generation) return;
      await widget.library.refreshAvailableOriginals();
      if (!mounted || generation != _generation) return;
      await for (final batch in _source.scan(
        folders: List.of(_folders),
        excludedPaths: [widget.library.repository.root.path],
        requestPermission: requestPermission,
      )) {
        if (!mounted || generation != _generation) return;
        setState(() {
          for (final entry in batch.entries) {
            _entries[entry.sourceId] = entry;
          }
          _audioAccess = batch.audioAccess;
          _videoAccess = batch.videoAccess;
          _warnings = {..._warnings, ...batch.warnings}.toList();
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _friendly(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _scanning = false;
          _selected.removeWhere((id) => !_entries.containsKey(id));
        });
        _refreshAfterResume();
      }
    }
  }

  Future<void> _stopScan() async {
    ++_generation;
    if (!_adding) _resumeRefreshPending = false;
    await _source.cancel();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _pickFolder() async {
    try {
      final folder = await FilePicker.getDirectoryPath(dialogTitle: '选择扫描文件夹');
      if (folder == null || !mounted) return;
      if (!_folders.contains(folder)) _folders.add(folder);
      await _scan();
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    }
  }

  List<MediaScanEntry> get _visible {
    final query = _search.trim().toLowerCase();
    final entries = _entries.values
        .where(
          (entry) =>
              (_category == 'all' || entry.category == _category) &&
              (query.isEmpty ||
                  entry.name.toLowerCase().contains(query) ||
                  entry.folder.toLowerCase().contains(query)),
        )
        .toList();
    entries.sort((a, b) {
      final order = switch (_sort) {
        'size' => b.sizeBytes.compareTo(a.sizeBytes),
        'recent' => b.modifiedMs.compareTo(a.modifiedMs),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return order == 0 ? a.sourceId.compareTo(b.sourceId) : order;
    });
    return entries;
  }

  List<MediaScanEntry> get _chosen => _entries.values
      .where(
        (entry) =>
            _selected.contains(entry.sourceId) &&
            !widget.library.isSourceImported(entry),
      )
      .toList();

  void _selectVisible(bool invert) {
    setState(() {
      for (final entry in _visible) {
        if (widget.library.isSourceImported(entry)) continue;
        if (invert && _selected.contains(entry.sourceId)) {
          _selected.remove(entry.sourceId);
        } else {
          _selected.add(entry.sourceId);
        }
      }
    });
  }

  Future<void> _add() async {
    final chosen = _chosen;
    if (chosen.isEmpty || _adding || widget.library.importing) return;
    setState(() {
      _adding = true;
      _stopAdding = false;
      _error = null;
      _summary = null;
    });
    final work = _performImport(chosen);
    _importFuture = work;
    await work;
    _importFuture = null;
  }

  Future<void> _performImport(List<MediaScanEntry> chosen) async {
    try {
      await _preview?.stop();
      await _stopScan();
      if (!mounted || _closing || _stopAdding) return;
      final result = await widget.library.importScanned(
        chosen,
        _source,
        groupId: _groupId,
      );
      if (!mounted) return;
      setState(() {
        _summary =
            '${result.cancelled ? '已停止，' : ''}已加入 ${result.imported} 项'
            '${result.skipped > 0 ? ' · 跳过重复 ${result.skipped} 项' : ''}'
            '${result.failed > 0 ? ' · 失败 ${result.failed} 项' : ''}';
        _error = result.failures.isEmpty
            ? null
            : result.failures.take(3).join('\n');
        _selected.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) setState(() => _adding = false);
      _refreshAfterResume();
    }
  }

  void _refreshAfterResume() {
    if (!mounted ||
        _closing ||
        _scanning ||
        _adding ||
        !_resumeRefreshPending) {
      return;
    }
    _resumeRefreshPending = false;
    unawaited(_scan());
  }

  Future<void> _close([String? result]) async {
    if (_closing) return;
    if (_adding) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('停止添加并返回？'),
          content: const Text('已加入的资源会保留，尚未完成的文件不会加入。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续添加'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('停止并返回'),
            ),
          ],
        ),
      );
      if (stop != true || !mounted) return;
      _closing = true;
      _stopAdding = true;
      widget.library.cancelImport();
      await _importFuture;
    }
    _closing = true;
    await _preview?.stop();
    await _stopScan();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, result);
    });
  }

  String _friendly(Object error) => error is PlatformException
      ? error.message ?? '无法读取本机媒体，请重试或手动选择文件。'
      : error is FormatException
      ? error.message
      : '无法完成操作，请检查文件权限或剩余空间后重试。';

  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_close(result));
    },
    child: AnimatedBuilder(
      animation: widget.library,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final visible = _visible;
        final chosen = _chosen;
        return Scaffold(
          appBar: AppBar(
            title: const Text('扫描本机'),
            titleTextStyle: Theme.of(context).textTheme.titleLarge,
            leading: IconButton(
              tooltip: '返回资源库',
              onPressed: _close,
              icon: const Icon(Icons.arrow_back),
            ),
            actions: [
              TextButton(
                onPressed: _adding ? null : () => _close('manual'),
                child: const Text('选择文件'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // With a keyboard or a short window, keep all actions
                    // reachable by scrolling instead of squeezing the list.
                    final compact = constraints.maxHeight < 400;
                    return Column(
                      children: [
                        if (_scanning)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: CustomScrollView(
                            slivers: [
                              SliverToBoxAdapter(child: _toolbar(colors)),
                              SliverToBoxAdapter(child: _notices(colors)),
                              if (visible.isEmpty)
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(28),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _scanning
                                                ? Icons.radar
                                                : Icons.library_music_outlined,
                                            size: 36,
                                            color: colors.onSurfaceVariant,
                                          ),
                                          const SizedBox(height: 14),
                                          Text(
                                            _scanning
                                                ? '正在查找本机媒体'
                                                : '没有找到匹配的文件',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            _android
                                                ? '可以调整媒体授权，或选择文件添加。'
                                                : '可以添加其他文件夹，或选择文件添加。',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                              else
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  sliver: SliverList.builder(
                                    itemCount: visible.length,
                                    itemBuilder: (context, index) =>
                                        _entry(visible[index], colors),
                                  ),
                                ),
                              if (compact)
                                SliverToBoxAdapter(
                                  child: _footer(chosen, colors),
                                ),
                            ],
                          ),
                        ),
                        if (_preview != null)
                          ScanPreviewStrip(
                            controller: _preview,
                            enabled: _canPreview,
                            compact: compact,
                            onOpenExternally: _canOpenExternally
                                ? (entry) => _sourceAction(entry, 'open')
                                : null,
                          ),
                        if (!compact) _footer(chosen, colors),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _toolbar(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (value) => setState(() => _search = value),
                decoration: const InputDecoration(
                  hintText: '搜索名称或文件夹',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '排序',
              initialValue: _sort,
              onSelected: (value) => setState(() => _sort = value),
              icon: const Icon(Icons.sort),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'name', child: Text('按名称排序')),
                PopupMenuItem(value: 'recent', child: Text('最近修改优先')),
                PopupMenuItem(value: 'size', child: Text('大文件优先')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'all', label: Text('全部')),
            ButtonSegment(value: 'audio', label: Text('音频')),
            ButtonSegment(value: 'video', label: Text('视频')),
          ],
          selected: {_category},
          onSelectionChanged: (value) =>
              setState(() => _category = value.first),
          style: SegmentedButton.styleFrom(
            minimumSize: const Size(0, 42),
            side: BorderSide.none,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            backgroundColor: colors.surfaceContainerLow,
            selectedBackgroundColor: colors.primaryContainer,
            selectedForegroundColor: colors.primary,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: _adding
                  ? null
                  : _scanning
                  ? _stopScan
                  : () => _scan(),
              icon: Icon(_scanning ? Icons.close : Icons.refresh, size: 18),
              label: Text(_scanning ? '停止扫描' : '重新扫描'),
            ),
            if (!_android)
              TextButton.icon(
                onPressed: _adding || _scanning ? null : _pickFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('添加文件夹'),
              ),
            Text(
              '${_entries.length} 项',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        if (_folders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final folder in _folders)
                  InputChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Tooltip(
                        message: folder,
                        child: Text(
                          folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    onDeleted: _adding || _scanning
                        ? null
                        : () {
                            _folders.remove(folder);
                            unawaited(_scan());
                          },
                  ),
              ],
            ),
          ),
        Wrap(
          spacing: 6,
          children: [
            TextButton(
              onPressed: _adding ? null : () => _selectVisible(false),
              child: const Text('全选当前列表'),
            ),
            TextButton(
              onPressed: _adding ? null : () => _selectVisible(true),
              child: const Text('反选'),
            ),
            TextButton(
              onPressed: _adding || _selected.isEmpty
                  ? null
                  : () => setState(_selected.clear),
              child: const Text('取消选择'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _notices(ColorScheme colors) {
    final restricted =
        _android && (_audioAccess != 'full' || _videoAccess != 'full');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (restricted)
          _notice(
            '${_audioAccess == 'denied' ? '音频尚未授权。' : ''}'
            '${_videoAccess == 'partial'
                ? '仅显示已授权的视频。'
                : _videoAccess == 'denied'
                ? '视频尚未授权。'
                : ''}',
            colors,
            action: TextButton(
              onPressed: _scanning || _adding
                  ? null
                  : () => _scan(requestPermission: true),
              child: const Text('调整授权'),
            ),
          ),
        if (_summary != null) _notice(_summary!, colors),
        if (_error != null) _notice(_error!, colors, error: true),
        if (_warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                '有 ${_warnings.length} 处位置未能完整扫描',
                style: const TextStyle(fontSize: 13),
              ),
              children: [
                for (final warning in _warnings.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(warning),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _notice(
    String text,
    ColorScheme colors, {
    bool error = false,
    Widget? action,
  }) => Container(
    margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: error ? colors.errorContainer : colors.primaryContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: TextStyle(
            color: error ? colors.onErrorContainer : colors.onPrimaryContainer,
            fontSize: 13,
          ),
        ),
        ?action,
      ],
    ),
  );

  Widget _entry(MediaScanEntry entry, ColorScheme colors) {
    final imported = widget.library.isSourceImported(entry);
    final selected = !imported && _selected.contains(entry.sourceId);
    final detail = [
      if (entry.durationMs > 0) _duration(entry.durationMs),
      _bytes(entry.sizeBytes),
      if (imported) '已加入',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.55)
            : colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Expanded(
              child: CheckboxListTile(
                value: selected,
                onChanged: _adding || imported
                    ? null
                    : (value) => setState(() {
                        value == true
                            ? _selected.add(entry.sourceId)
                            : _selected.remove(entry.sourceId);
                      }),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                title: Text(
                  entry.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 12,
                        color: imported
                            ? colors.primary
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    if (entry.folder.isNotEmpty)
                      Text(
                        entry.folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (entry.category == 'audio' && _preview != null)
              _previewButton(entry, colors),
            PopupMenuButton<String>(
              key: ValueKey('source-actions-${entry.sourceId}'),
              tooltip: '文件操作',
              enabled: !_adding && !_closing,
              icon: Icon(Icons.more_horiz, color: colors.onSurfaceVariant),
              onSelected: (action) => _sourceAction(entry, action),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'open',
                  enabled: _canOpenExternally,
                  child: const Text('用其他播放器打开'),
                ),
                if (!_android)
                  const PopupMenuItem(value: 'reveal', child: Text('在文件夹中显示')),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _previewButton(MediaScanEntry entry, ColorScheme colors) {
    final preview = _preview!;
    final current = preview.entry?.sourceId == entry.sourceId;
    final loading = current && preview.state == PreviewState.loading;
    final playing = current && preview.state == PreviewState.playing;
    return IconButton(
      key: ValueKey('preview-${entry.sourceId}'),
      tooltip: !widget.canPreview || !preview.allowed
          ? '退出组队后可试听'
          : playing
          ? '暂停试听'
          : current && preview.state == PreviewState.paused
          ? '继续试听'
          : '试听',
      onPressed: _canPreview && !loading ? () => _playPreview(entry) : null,
      color: current ? colors.primary : colors.onSurfaceVariant,
      icon: loading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 24,
            ),
    );
  }

  Widget _footer(List<MediaScanEntry> chosen, ColorScheme colors) {
    final library = widget.library;
    final group = _groupId != null && library.groupById(_groupId!) != null
        ? _groupId
        : null;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_adding) ...[
            LinearProgressIndicator(
              value: library.importTotal > 0
                  ? library.importCompleted / library.importTotal
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              '正在添加 ${library.importCompleted} / ${library.importTotal}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (library.importCurrentName != null)
              Text(
                library.importCurrentName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            TextButton(
              onPressed: () {
                _stopAdding = true;
                library.cancelImport();
              },
              child: const Text('停止添加'),
            ),
          ] else ...[
            Text(
              '已选 ${chosen.length} 项 · ${_bytes(chosen.fold<int>(0, (total, entry) => total + entry.sizeBytes))}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final target = DropdownButtonFormField<String>(
                  key: ValueKey(group),
                  initialValue: group ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '加入分组',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('未分组')),
                    for (final group in library.groups)
                      DropdownMenuItem(
                        value: group.id,
                        child: Text(
                          group.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _groupId = value == '' ? null : value),
                );
                final add = FilledButton.icon(
                  onPressed: chosen.isEmpty || library.importing ? null : _add,
                  icon: const Icon(Icons.add, size: 19),
                  label: const Text('加入资源库'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                );
                if (constraints.maxWidth < 480) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [target, const SizedBox(height: 10), add],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: target),
                    const SizedBox(width: 16),
                    add,
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  static String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _duration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
