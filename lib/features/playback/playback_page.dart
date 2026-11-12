import 'package:flutter/material.dart';
import '../../app/components.dart';
import '../../app/desktop_components.dart';
import '../../app/mobile_components.dart';
import '../../session/session_controller.dart';

class PlaybackPage extends StatelessWidget {
  const PlaybackPage({
    super.key,
    required this.session,
    required this.selectLibrary,
  });
  final SessionController session;
  final VoidCallback selectLibrary;
  @override
  Widget build(BuildContext context) =>
      isMobileLayout(context) ? _mobile(context) : _desktop(context);

  Widget _desktop(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final track = session.currentTrack;
    final preparing =
        session.phase == SessionPhase.preparing ||
        session.phase == SessionPhase.scheduled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(title: '正在播放'),
        const SizedBox(height: 22),
        if (track == null)
          DesktopSection(
            key: const ValueKey('desktop-player-empty'),
            child: EmptyPanel(
              icon: Icons.album_outlined,
              title: session.masterSelectionRequired ? '等待确认主控' : '等待播放',
              description: session.masterSelectionRequired
                  ? '请到设备页重新选择主控。'
                  : session.isMaster
                  ? '选一首音乐，一起聆听。'
                  : '主控开始后自动同步播放。',
              action: session.isMaster
                  ? DesktopActionButton(
                      label: '打开资源库',
                      icon: Icons.library_music_outlined,
                      primary: true,
                      onPressed: session.canSelectResources
                          ? selectLibrary
                          : null,
                    )
                  : null,
            ),
          )
        else
          DesktopColumns(
            primary: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.graphic_eq,
                              size: 27,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  preparing
                                      ? session.phase == SessionPhase.scheduled
                                            ? '即将同步播放'
                                            : '正在准备音频'
                                      : '${session.members.length} 台设备 · 同步播放',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      LinearProgressIndicator(
                        value: preparing
                            ? null
                            : track.durationMs > 0
                            ? (session.positionMs / track.durationMs).clamp(
                                0,
                                1,
                              )
                            : 0,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(3),
                        backgroundColor: colors.primary.withValues(alpha: 0.1),
                        color: colors.primary,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatDuration(session.positionMs),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            formatDuration(track.durationMs),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      if (session.isMaster)
                        LayoutBuilder(
                          builder: (context, box) {
                            // Icon-only controls keep their touch targets at large
                            // text sizes; wrap only when four 48dp targets won't fit.
                            final columns = box.maxWidth < 216 ? 2 : 4;
                            final width =
                                ((box.maxWidth - (columns - 1) * 8) / columns)
                                    .clamp(48.0, 80.0)
                                    .toDouble();
                            final controls = <Widget>[
                              _PlaybackControl(
                                key: const ValueKey('desktop-previous'),
                                label: '上一首',
                                icon: Icons.skip_previous_rounded,
                                onPressed: session.canPreviousTrack
                                    ? () => reportAction(
                                        context,
                                        session.previousTrack,
                                      )
                                    : null,
                              ),
                              _PlaybackControl(
                                key: const ValueKey('desktop-next'),
                                label: '下一首',
                                icon: Icons.skip_next_rounded,
                                onPressed: session.canNextTrack
                                    ? () => reportAction(
                                        context,
                                        session.nextTrack,
                                      )
                                    : null,
                              ),
                              _PlaybackControl(
                                key: const ValueKey('desktop-stop'),
                                label: '结束播放',
                                icon: Icons.stop_rounded,
                                primary: true,
                                onPressed: () =>
                                    reportAction(context, session.endPlayback),
                              ),
                              _PlaybackControl(
                                key: const ValueKey('desktop-library'),
                                label: '切换资源',
                                icon: Icons.queue_music_rounded,
                                onPressed: session.canSelectResources
                                    ? selectLibrary
                                    : null,
                              ),
                            ];
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final control in controls)
                                  SizedBox(width: width, child: control),
                              ],
                            );
                          },
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          child: DesktopActionButton(
                            label: '停止并退出',
                            icon: Icons.logout,
                            destructive: true,
                            onPressed: () =>
                                reportAction(context, session.leave),
                          ),
                        ),
                      if (session.focusAttenuation < 1) ...[
                        const SizedBox(height: 14),
                        Text(
                          session.focusAttenuation == 0
                              ? '本机暂时静音，播放保持同步'
                              : '本机已降低音量，播放保持同步',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: DesktopActionButton(
                            label: '恢复本机声音',
                            icon: Icons.volume_up_outlined,
                            onPressed: () => reportAction(
                              context,
                              session.restoreLocalAudioFocus,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                DesktopSectionHeader(
                  title: '本次播放列表',
                  trailing: Text(
                    '${session.queue.length} 首',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                DesktopSection(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (session.isMaster)
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<PlaybackMode>(
                            segments: const [
                              ButtonSegment(
                                value: PlaybackMode.sequential,
                                icon: Icon(
                                  Icons.format_list_numbered,
                                  size: 17,
                                ),
                                label: Text('顺序播放'),
                              ),
                              ButtonSegment(
                                value: PlaybackMode.random,
                                icon: Icon(Icons.shuffle, size: 17),
                                label: Text('随机播放'),
                              ),
                            ],
                            selected: {session.playbackMode},
                            showSelectedIcon: false,
                            onSelectionChanged: session.canSelectResources
                                ? (value) =>
                                      session.setPlaybackMode(value.first)
                                : null,
                            style: ButtonStyle(
                              minimumSize: const WidgetStatePropertyAll(
                                Size(0, 44),
                              ),
                              padding: const WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 8),
                              ),
                              textStyle: const WidgetStatePropertyAll(
                                TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              side: const WidgetStatePropertyAll(
                                BorderSide.none,
                              ),
                              shape: WidgetStatePropertyAll(
                                RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              backgroundColor: WidgetStateProperty.resolveWith(
                                (states) =>
                                    states.contains(WidgetState.selected)
                                    ? colors.primaryContainer
                                    : colors.surfaceContainerLow,
                              ),
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 8),
                          child: Text(
                            session.playbackMode == PlaybackMode.random
                                ? '随机播放 · 由主控切歌'
                                : '顺序播放 · 由主控切歌',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (session.modeChangePending)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(5, 9, 5, 3),
                          child: Text(
                            '下一首生效 · ${session.playbackMode == PlaybackMode.random ? '随机播放' : '顺序播放'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      const SizedBox(height: 6),
                      for (final entry in session.queue.indexed) ...[
                        if (entry.$1 > 0)
                          const Padding(
                            padding: EdgeInsets.only(left: 38, right: 6),
                            child: Divider(),
                          ),
                        Material(
                          color: entry.$1 == session.queueIndex
                              ? colors.primary.withValues(alpha: 0.055)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            key: ValueKey('queue-track-${entry.$1}'),
                            borderRadius: BorderRadius.circular(10),
                            onTap:
                                session.canSelectResources &&
                                    entry.$1 != session.queueIndex
                                ? () => reportAction(
                                    context,
                                    () => session.selectQueueTrack(entry.$1),
                                  )
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 15,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 30,
                                    child: entry.$1 == session.queueIndex
                                        ? Icon(
                                            Icons.graphic_eq,
                                            color: colors.primary,
                                            size: 19,
                                          )
                                        : Text(
                                            '${entry.$1 + 1}',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 3),
                                  Expanded(
                                    child: Text(
                                      entry.$2.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight:
                                            entry.$1 == session.queueIndex
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: entry.$1 == session.queueIndex
                                            ? colors.primary
                                            : colors.onSurface,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    formatDuration(entry.$2.durationMs),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (session.skippedCount > 0)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            '已跳过 ${session.skippedCount} 项不可播放资源',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            secondary: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DesktopDisclosure(
                  title: '参与设备',
                  subtitle: preparing
                      ? '${session.readyDeviceIds.length}/${session.members.length} 台已就绪'
                      : '${session.members.length} 台设备已连接',
                  icon: Icons.speaker_group_outlined,
                  storageId: 'playback-desktop-members',
                  children: [
                    for (final member in session.members)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          children: [
                            Icon(
                              member.platform.toLowerCase().contains('android')
                                  ? Icons.smartphone
                                  : Icons.desktop_windows_outlined,
                              size: 20,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(member.name)),
                            const SizedBox(width: 8),
                            StatusBadge(
                              preparing
                                  ? session.readyDeviceIds.contains(member.id)
                                        ? '已就绪'
                                        : '准备中'
                                  : '播放中',
                              warning:
                                  preparing &&
                                  !session.readyDeviceIds.contains(member.id),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DesktopDisclosure(
                  title: '连接与缓冲详情',
                  icon: Icons.tune,
                  storageId: 'playback-desktop-diagnostics',
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('本机缓冲'),
                        Text('${session.bufferSeconds.toStringAsFixed(2)} 秒'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('校时往返'),
                        Text(
                          '${(session.clockRttMicros / 1000).toStringAsFixed(2)} ms',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '诊断数值不代表实际出声偏差。',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _mobile(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final track = session.currentTrack;
    final preparing =
        session.phase == SessionPhase.preparing ||
        session.phase == SessionPhase.scheduled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(title: '正在播放'),
        const SizedBox(height: 22),
        if (track == null)
          MobileSection(
            key: const ValueKey('mobile-player-empty'),
            child: EmptyPanel(
              icon: Icons.album_outlined,
              title: session.masterSelectionRequired ? '等待确认主控' : '等待播放',
              description: session.masterSelectionRequired
                  ? '请到设备页重新选择主控。'
                  : session.isMaster
                  ? '选一首音乐，一起聆听。'
                  : '主控开始后自动同步播放。',
              action: session.isMaster
                  ? MobileActionButton(
                      label: '打开资源库',
                      icon: Icons.library_music_outlined,
                      primary: true,
                      onPressed: session.canSelectResources
                          ? selectLibrary
                          : null,
                    )
                  : null,
            ),
          )
        else ...[
          MobileSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.graphic_eq,
                        size: 27,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            preparing
                                ? session.phase == SessionPhase.scheduled
                                      ? '即将同步播放'
                                      : '正在准备音频'
                                : '${session.members.length} 台设备 · 同步播放',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                LinearProgressIndicator(
                  value: preparing
                      ? null
                      : track.durationMs > 0
                      ? (session.positionMs / track.durationMs).clamp(0, 1)
                      : 0,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(3),
                  backgroundColor: colors.primary.withValues(alpha: 0.1),
                  color: colors.primary,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      formatDuration(session.positionMs),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      formatDuration(track.durationMs),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (session.isMaster)
                  LayoutBuilder(
                    builder: (context, box) {
                      // Icon-only controls keep their touch targets at large
                      // text sizes; wrap only when four 48dp targets won't fit.
                      final columns = box.maxWidth < 216 ? 2 : 4;
                      final width =
                          (box.maxWidth - (columns - 1) * 8) / columns;
                      final controls = <Widget>[
                        _PlaybackControl(
                          key: const ValueKey('mobile-previous'),
                          label: '上一首',
                          icon: Icons.skip_previous_rounded,
                          onPressed: session.canPreviousTrack
                              ? () =>
                                    reportAction(context, session.previousTrack)
                              : null,
                        ),
                        _PlaybackControl(
                          key: const ValueKey('mobile-next'),
                          label: '下一首',
                          icon: Icons.skip_next_rounded,
                          onPressed: session.canNextTrack
                              ? () => reportAction(context, session.nextTrack)
                              : null,
                        ),
                        _PlaybackControl(
                          key: const ValueKey('mobile-stop'),
                          label: '结束播放',
                          icon: Icons.stop_rounded,
                          primary: true,
                          onPressed: () =>
                              reportAction(context, session.endPlayback),
                        ),
                        _PlaybackControl(
                          key: const ValueKey('mobile-library'),
                          label: '切换资源',
                          icon: Icons.queue_music_rounded,
                          onPressed: session.canSelectResources
                              ? selectLibrary
                              : null,
                        ),
                      ];
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final control in controls)
                            SizedBox(width: width, child: control),
                        ],
                      );
                    },
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: MobileActionButton(
                      label: '停止并退出',
                      icon: Icons.logout,
                      destructive: true,
                      onPressed: () => reportAction(context, session.leave),
                    ),
                  ),
                if (session.focusAttenuation < 1) ...[
                  const SizedBox(height: 14),
                  Text(
                    session.focusAttenuation == 0
                        ? '本机暂时静音，播放保持同步'
                        : '本机已降低音量，播放保持同步',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: MobileActionButton(
                      label: '恢复本机声音',
                      icon: Icons.volume_up_outlined,
                      onPressed: () =>
                          reportAction(context, session.restoreLocalAudioFocus),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 26),
          MobileSectionHeader(
            title: '本次播放列表',
            trailing: Text(
              '${session.queue.length} 首',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ),
          MobileSection(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (session.isMaster)
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<PlaybackMode>(
                      segments: const [
                        ButtonSegment(
                          value: PlaybackMode.sequential,
                          icon: Icon(Icons.format_list_numbered, size: 17),
                          label: Text('顺序播放'),
                        ),
                        ButtonSegment(
                          value: PlaybackMode.random,
                          icon: Icon(Icons.shuffle, size: 17),
                          label: Text('随机播放'),
                        ),
                      ],
                      selected: {session.playbackMode},
                      showSelectedIcon: false,
                      onSelectionChanged: session.canSelectResources
                          ? (value) => session.setPlaybackMode(value.first)
                          : null,
                      style: ButtonStyle(
                        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 8),
                        ),
                        textStyle: const WidgetStatePropertyAll(
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        side: const WidgetStatePropertyAll(BorderSide.none),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? colors.primaryContainer
                              : colors.surfaceContainerLow,
                        ),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(5, 0, 5, 8),
                    child: Text(
                      session.playbackMode == PlaybackMode.random
                          ? '随机播放 · 由主控切歌'
                          : '顺序播放 · 由主控切歌',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (session.modeChangePending)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(5, 9, 5, 3),
                    child: Text(
                      '下一首生效 · ${session.playbackMode == PlaybackMode.random ? '随机播放' : '顺序播放'}',
                      style: TextStyle(fontSize: 12, color: colors.primary),
                    ),
                  ),
                const SizedBox(height: 6),
                for (final entry in session.queue.indexed) ...[
                  if (entry.$1 > 0)
                    const Padding(
                      padding: EdgeInsets.only(left: 38, right: 6),
                      child: Divider(),
                    ),
                  Material(
                    color: entry.$1 == session.queueIndex
                        ? colors.primary.withValues(alpha: 0.055)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      key: ValueKey('queue-track-${entry.$1}'),
                      borderRadius: BorderRadius.circular(10),
                      onTap:
                          session.canSelectResources &&
                              entry.$1 != session.queueIndex
                          ? () => reportAction(
                              context,
                              () => session.selectQueueTrack(entry.$1),
                            )
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 15,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 30,
                              child: entry.$1 == session.queueIndex
                                  ? Icon(
                                      Icons.graphic_eq,
                                      color: colors.primary,
                                      size: 19,
                                    )
                                  : Text(
                                      '${entry.$1 + 1}',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                entry.$2.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: entry.$1 == session.queueIndex
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: entry.$1 == session.queueIndex
                                      ? colors.primary
                                      : colors.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              formatDuration(entry.$2.durationMs),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (session.skippedCount > 0)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '已跳过 ${session.skippedCount} 项不可播放资源',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          MobileDisclosure(
            title: '参与设备',
            subtitle: preparing
                ? '${session.readyDeviceIds.length}/${session.members.length} 台已就绪'
                : '${session.members.length} 台设备已连接',
            icon: Icons.speaker_group_outlined,
            storageId: 'playback-mobile-members',
            children: [
              for (final member in session.members)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Row(
                    children: [
                      Icon(
                        member.platform.toLowerCase().contains('android')
                            ? Icons.smartphone
                            : Icons.desktop_windows_outlined,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(member.name)),
                      const SizedBox(width: 8),
                      StatusBadge(
                        preparing
                            ? session.readyDeviceIds.contains(member.id)
                                  ? '已就绪'
                                  : '准备中'
                            : '播放中',
                        warning:
                            preparing &&
                            !session.readyDeviceIds.contains(member.id),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          MobileDisclosure(
            title: '连接与缓冲详情',
            icon: Icons.tune,
            storageId: 'playback-mobile-diagnostics',
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('本机缓冲'),
                  Text('${session.bufferSeconds.toStringAsFixed(2)} 秒'),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('校时往返'),
                  Text(
                    '${(session.clockRttMicros / 1000).toStringAsFixed(2)} ms',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '诊断数值不代表实际出声偏差。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PlaybackControl extends StatelessWidget {
  const _PlaybackControl({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.primary = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 56,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: IconButton(
          onPressed: onPressed,
          iconSize: 27,
          style: IconButton.styleFrom(
            minimumSize: const Size(double.infinity, 56),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
            backgroundColor: primary
                ? colors.primary
                : colors.surfaceContainerLow,
            foregroundColor: primary ? colors.onPrimary : colors.primary,
            disabledBackgroundColor: colors.surfaceContainerLow,
            disabledForegroundColor: colors.onSurface.withValues(alpha: 0.3),
          ),
          icon: Icon(icon, semanticLabel: label),
        ),
      ),
    );
  }
}
