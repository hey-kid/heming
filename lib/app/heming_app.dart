import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/library_controller.dart';
import '../data/library_models.dart';
import '../features/devices/devices_page.dart';
import '../features/library/library_page.dart';
import '../features/playback/playback_page.dart';
import '../features/settings/settings_page.dart';
import '../session/session_controller.dart';
import '../preview/preview_controller.dart';
import 'preferences.dart';
import 'theme.dart';

class HemingApp extends StatefulWidget {
  const HemingApp({
    super.key,
    required this.session,
    required this.library,
    required this.preferences,
    this.preview,
  });
  final SessionController session;
  final LibraryController library;
  final Preferences preferences;
  final PreviewController? preview;
  @override
  State<HemingApp> createState() => _HemingAppState();
}

class _HemingAppState extends State<HemingApp> {
  int _page = 0;
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  String? _lastLibraryMessage;
  late final Listenable _updates = Listenable.merge([
    widget.session,
    widget.library,
    widget.preferences,
  ]);
  @override
  void initState() {
    super.initState();
    widget.library.addListener(_onLibraryNotice);
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryNotice);
    super.dispose();
  }

  void _onLibraryNotice() {
    final message = widget.library.message;
    if (message != null && message != _lastLibraryMessage) {
      _lastLibraryMessage = message;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _messenger.currentState?.showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      });
    }
  }

  void _selectPage(int page) {
    if (_page == 1 && page != 1) unawaited(widget.preview?.stop());
    setState(() => _page = page);
  }

  void _selectLibrary() => _selectPage(1);

  PlayableTrack _track(LibraryItem item) => PlayableTrack(
    id: item.id,
    title: item.title,
    path: item.playablePath ?? '',
    durationMs: item.durationMs,
    isPlayable: item.isPlayable,
  );
  Future<void> _play(LibraryItem item) async {
    await widget.preview?.stop();
    if (item.groupId != null) {
      final items = widget.library.itemsInGroup(item.groupId);
      final index = items.indexWhere((entry) => entry.id == item.id);
      if (index < 0) return;
      await _playlist(items, startIndex: index);
      return;
    }
    if (!await widget.library.validateForPlayback(item.id)) {
      throw StateError('资源不可播放，请先检测或转换。');
    }
    await widget.session.play(_track(item));
    if (mounted && widget.session.currentTrack != null) {
      setState(() => _page = 2);
    }
  }

  Future<void> _playlist(List<LibraryItem> items, {int startIndex = 0}) async {
    await widget.preview?.stop();
    final tracks = <PlayableTrack>[];
    for (final item in items) {
      final ready =
          item.isPlayable && await widget.library.validateForPlayback(item.id);
      tracks.add(
        PlayableTrack(
          id: item.id,
          title: item.title,
          path: ready ? item.playablePath! : '',
          durationMs: item.durationMs,
          isPlayable: ready,
        ),
      );
    }
    await widget.session.startPlaylist(tracks, startIndex: startIndex);
    if (mounted && widget.session.currentTrack != null) {
      setState(() => _page = 2);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _updates,
    builder: (context, _) => LayoutBuilder(
      builder: (context, viewport) => MaterialApp(
        title: '和鸣',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messenger,
        theme: hemingTheme(
          Brightness.light,
          mobile: viewport.maxWidth < 860,
          accent: widget.preferences.themeAccent,
        ),
        darkTheme: hemingTheme(
          Brightness.dark,
          mobile: viewport.maxWidth < 860,
          accent: widget.preferences.themeAccent,
        ),
        themeMode: widget.preferences.themeMode,
        home: Builder(
          builder: (context) => LayoutBuilder(
            builder: (context, constraints) {
              final desktop = constraints.maxWidth >= 860;
              final session = widget.session;
              final colors = Theme.of(context).colorScheme;
              final page = switch (_page) {
                0 => DevicesPage(
                  session: session,
                  selectLibrary: _selectLibrary,
                  beforeConnect: widget.preview?.stop,
                ),
                1 => LibraryPage(
                  library: widget.library,
                  canPlay: session.canSelectResources,
                  canPreview: !session.isConnected && !session.isJoining,
                  preview: widget.preview,
                  onPlay: _play,
                  onPlaylist: _playlist,
                ),
                2 => PlaybackPage(
                  session: session,
                  selectLibrary: _selectLibrary,
                ),
                _ => SettingsPage(
                  session: session,
                  library: widget.library,
                  preferences: widget.preferences,
                ),
              };
              final scaffold = Scaffold(
                body: SafeArea(
                  child: Row(
                    children: [
                      if (desktop) _sidebar(context),
                      Expanded(
                        child: Column(
                          children: [
                            _header(context, desktop),
                            Expanded(
                              child: SingleChildScrollView(
                                key: PageStorageKey('page-$_page'),
                                padding: desktop
                                    ? const EdgeInsets.fromLTRB(28, 20, 28, 32)
                                    : const EdgeInsets.fromLTRB(20, 12, 20, 28),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1160,
                                    ),
                                    child: page,
                                  ),
                                ),
                              ),
                            ),
                            if (session.error != null ||
                                session.message != null)
                              Container(
                                width: double.infinity,
                                margin: desktop
                                    ? const EdgeInsets.fromLTRB(28, 0, 28, 18)
                                    : null,
                                padding: const EdgeInsets.only(
                                  left: 18,
                                  right: 6,
                                  top: 5,
                                  bottom: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: session.error != null
                                      ? colors.errorContainer
                                      : colors.primaryContainer,
                                  borderRadius: desktop
                                      ? BorderRadius.circular(12)
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      session.error != null
                                          ? Icons.error_outline
                                          : Icons.info_outline,
                                      size: 17,
                                      color: session.error != null
                                          ? colors.onErrorContainer
                                          : colors.onPrimaryContainer,
                                    ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Text(
                                        session.error ?? session.message!,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: session.error != null
                                              ? colors.onErrorContainer
                                              : colors.onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: session.clearNotice,
                                      icon: const Icon(Icons.close, size: 16),
                                      tooltip: '关闭提示',
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: desktop
                    ? null
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: colors.outlineVariant,
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: NavigationBar(
                          selectedIndex: _page,
                          onDestinationSelected: _selectPage,
                          height: 66,
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.sensors),
                              label: '设备',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.library_music_outlined),
                              label: '资源库',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.album_outlined),
                              label: '正在播放',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.settings_outlined),
                              label: '设置',
                            ),
                          ],
                        ),
                      ),
              );
              if (desktop) return scaffold;
              final dark = Theme.of(context).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: SystemUiOverlayStyle(
                  statusBarColor: colors.surface,
                  statusBarBrightness: dark
                      ? Brightness.dark
                      : Brightness.light,
                  statusBarIconBrightness: dark
                      ? Brightness.light
                      : Brightness.dark,
                  systemStatusBarContrastEnforced: false,
                  systemNavigationBarColor: colors.surfaceContainerLowest,
                  systemNavigationBarIconBrightness: dark
                      ? Brightness.light
                      : Brightness.dark,
                  systemNavigationBarContrastEnforced: false,
                ),
                child: scaffold,
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _header(BuildContext context, bool desktop) {
    final session = widget.session;
    final colors = Theme.of(context).colorScheme;
    final phase = switch (session.phase) {
      SessionPhase.disconnected => session.isJoining ? '等待接受' : '未连接',
      SessionPhase.standby => session.masterSelectionRequired ? '待选主控' : '已连接',
      SessionPhase.preparing => '正在准备',
      SessionPhase.scheduled => '即将播放',
      SessionPhase.playing => '同步播放中',
    };
    if (!desktop) {
      final compactPhase = switch (session.phase) {
        SessionPhase.disconnected => session.isJoining ? '等待接受' : '未连接',
        SessionPhase.standby =>
          session.masterSelectionRequired ? '待选主控' : '已连接',
        SessionPhase.preparing => '正在准备',
        SessionPhase.scheduled => '即将播放',
        SessionPhase.playing => '同步播放中',
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 3),
        child: Row(
          children: [
            Icon(Icons.graphic_eq, size: 17, color: colors.primary),
            const SizedBox(width: 6),
            Text(
              '和鸣',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (session.isJoining || session.phase == SessionPhase.preparing)
              SizedBox.square(
                dimension: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colors.primary,
                ),
              )
            else
              Icon(
                Icons.circle,
                size: 5,
                color: session.isConnected
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            const SizedBox(width: 6),
            Text(
              compactPhase,
              style: TextStyle(
                fontSize: 12,
                color: session.isConnected
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Row(
        children: [
          Icon(Icons.wifi_rounded, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '局域网',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          if (session.phase == SessionPhase.preparing || session.isJoining)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(
                dimension: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            )
          else
            Icon(
              Icons.circle,
              size: 6,
              color: session.isConnected
                  ? colors.primary
                  : colors.onSurfaceVariant,
            ),
          const SizedBox(width: 6),
          Text(
            phase,
            style: TextStyle(
              color: session.isConnected
                  ? colors.primary
                  : colors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('desktop-sidebar'),
      width: 208,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border(
          right: BorderSide(color: colors.outlineVariant, width: 0.5),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10, bottom: 34),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.graphic_eq,
                            color: colors.onPrimary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '和鸣',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                  ...[
                    (Icons.sensors, '设备'),
                    (Icons.library_music_outlined, '资源库'),
                    (Icons.album_outlined, '正在播放'),
                  ].indexed.map(
                    (entry) =>
                        _navItem(context, entry.$1, entry.$2.$1, entry.$2.$2),
                  ),
                  const Spacer(),
                  _navItem(context, 3, Icons.settings_outlined, '设置'),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 17),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: Row(
                      children: [
                        Icon(
                          Icons.desktop_windows_outlined,
                          size: 17,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.session.localDevice.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              Text(
                                widget.session.isMaster
                                    ? (widget.session.masterSelectionRequired
                                          ? '主控待确认'
                                          : '主控设备')
                                    : widget.session.isConnected
                                    ? '跟随设备'
                                    : '本机',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(
    BuildContext context,
    int index,
    IconData icon,
    String label,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: _page == index
            ? colors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _selectPage(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: _page == index
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: _page == index
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: _page == index
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
