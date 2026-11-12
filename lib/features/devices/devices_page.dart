import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/components.dart';
import '../../app/desktop_components.dart';
import '../../app/mobile_components.dart';
import '../../session/session_controller.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({
    super.key,
    required this.session,
    required this.selectLibrary,
    this.beforeConnect,
  });
  final SessionController session;
  final VoidCallback selectLibrary;
  final Future<void> Function()? beforeConnect;

  Future<void> _createRoom() async {
    await beforeConnect?.call();
    await session.createRoom();
  }

  Future<void> _connect(String host, {required int port}) async {
    await beforeConnect?.call();
    await session.join(host, port: port);
  }

  Future<void> _join(BuildContext context) async {
    final input = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接主控设备'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('连接同一局域网后，输入主控设备显示的地址。'),
            const SizedBox(height: 18),
            TextField(
              controller: input,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '主控地址',
                hintText: '192.168.1.10:19786',
              ),
              onSubmitted: (value) => Navigator.pop(context, value.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('申请加入'),
          ),
        ],
      ),
    );
    // TextField may still be animating out while the dialog future completes.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (address == null || address.isEmpty) return;
    final uri = Uri.tryParse(
      address.contains('://') ? address : 'ws://$address',
    );
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('请输入有效的 IP 地址和端口。');
    }
    await _connect(uri.host, port: uri.hasPort ? uri.port : 19786);
  }

  @override
  Widget build(BuildContext context) =>
      isMobileLayout(context) ? _mobilePage(context) : _desktopPage(context);

  Widget _desktopPage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final locked = [
      SessionPhase.preparing,
      SessionPhase.scheduled,
      SessionPhase.playing,
    ].contains(session.phase);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(title: '设备'),
        const SizedBox(height: 24),
        DesktopColumns(
          primary: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _desktopOverview(context),
              if (session.masterSelectionRequired) ...[
                const SizedBox(height: 20),
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const DesktopSectionHeader(title: '重新确认主控'),
                      Text(
                        session.isMaster
                            ? '播放已停止。继续主控，或接受其他设备接管。'
                            : '播放已停止。等待主控确认，或申请接管。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      if (session.isMaster) ...[
                        const SizedBox(height: 16),
                        DesktopActionButton(
                          label: '继续由本机主控',
                          icon: Icons.check_circle_outline,
                          primary: true,
                          onPressed: () => reportAction(
                            context,
                            session.confirmMasterSelection,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (session.pendingJoins.isNotEmpty) ...[
                const SizedBox(height: 20),
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DesktopSectionHeader(
                        title: '加入申请',
                        trailing: Text('${session.pendingJoins.length}'),
                      ),
                      for (final entry in session.pendingJoins.indexed) ...[
                        if (entry.$1 > 0) const Divider(),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.$2.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                entry.$2.device.platform,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  DesktopActionButton(
                                    label: '接受',
                                    icon: Icons.check,
                                    primary: true,
                                    onPressed: locked
                                        ? null
                                        : () => reportAction(
                                            context,
                                            () => session.approveJoin(
                                              entry.$2.id,
                                            ),
                                          ),
                                  ),
                                  DesktopActionButton(
                                    label: '拒绝',
                                    icon: Icons.close,
                                    onPressed: () => reportAction(
                                      context,
                                      () => session.rejectJoin(entry.$2.id),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (session.isMaster && session.takeoverRequester != null) ...[
                const SizedBox(height: 20),
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const DesktopSectionHeader(title: '主控接管申请'),
                      Text(
                        '${session.members.where((member) => member.id == session.takeoverRequester).map((member) => member.name).firstOrNull ?? '组内设备'}希望成为主控',
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '移交将结束当前播放，并清空缓冲。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          DesktopActionButton(
                            label: '停止并移交',
                            icon: Icons.swap_horiz,
                            primary: true,
                            onPressed: () =>
                                reportAction(context, session.approveTakeover),
                          ),
                          DesktopActionButton(
                            label: '拒绝',
                            icon: Icons.close,
                            onPressed: () =>
                                reportAction(context, session.rejectTakeover),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              if (session.isConnected)
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DesktopSectionHeader(
                        title: '组内设备',
                        trailing: Text(
                          '${session.members.length} / 6',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                      _mobileMembers(context),
                    ],
                  ),
                )
              else
                DesktopDisclosure(
                  title: '本机输出',
                  icon: Icons.volume_up_outlined,
                  storageId: 'devices-desktop-local-output',
                  subtitle:
                      '${channelName(session.localDevice.channel)} · ${session.localDevice.muted ? '已静音' : '${(session.localDevice.volume * 100).round()}%'}',
                  children: [_mobileMembers(context)],
                ),
            ],
          ),
          secondary: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (session.isMaster) ...[
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const DesktopSectionHeader(title: '连接地址'),
                      _mobileAddresses(context),
                      const SizedBox(height: 10),
                      Text(
                        locked ? '播放中，暂不接受新设备' : '其他设备申请后，由你确认。',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (session.isConnected)
                DesktopDisclosure(
                  title: '附近播放组',
                  icon: Icons.radar,
                  storageId: 'devices-desktop-nearby',
                  children: [_desktopNearby(context, showHeading: false)],
                )
              else
                DesktopSection(child: _desktopNearby(context)),
              if (session.isConnected) ...[
                const SizedBox(height: 20),
                DesktopSection(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!session.isMaster) ...[
                        DesktopActionButton(
                          label: '申请成为主控',
                          icon: Icons.swap_horiz,
                          onPressed: session.takeoverRequester != null
                              ? null
                              : () => reportAction(
                                  context,
                                  session.requestTakeover,
                                ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      DesktopActionButton(
                        label: session.isMaster ? '解散播放组' : '退出播放组',
                        icon: Icons.logout,
                        destructive: true,
                        onPressed: () => reportAction(context, session.leave),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _desktopOverview(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DesktopSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _mobileDeviceIcon(context, Icons.sensors, prominent: true),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.isConnected
                          ? (session.isMaster ? '我的播放组' : '已加入播放组')
                          : '一起聆听',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      session.isConnected
                          ? '${session.members.length} 台设备 · ${session.masterSelectionRequired
                                ? '等待确认主控'
                                : session.isMaster
                                ? '本机主控'
                                : '跟随主控'}'
                          : '连接同一网络下的设备，共享一段声音。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (session.isMaster || !session.isConnected) ...[
            const SizedBox(height: 24),
            DesktopActionButton(
              label: session.isMaster ? '选择资源' : '创建播放组',
              icon: session.isMaster ? Icons.music_note_outlined : Icons.add,
              primary: true,
              onPressed: session.isMaster
                  ? (session.canSelectResources ? selectLibrary : null)
                  : session.isJoining
                  ? null
                  : () => reportAction(context, _createRoom),
            ),
          ],
          if (session.isJoining) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 10),
                const Expanded(child: Text('等待主控接受')),
                TextButton(
                  onPressed: () => reportAction(context, session.leave),
                  child: const Text('取消加入'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _desktopNearby(BuildContext context, {bool showHeading = true}) {
    final colors = Theme.of(context).colorScheme;
    final refresh = IconButton(
      tooltip: '刷新附近播放组',
      onPressed: () => reportAction(context, session.restartDiscovery),
      icon: const Icon(Icons.refresh, size: 20),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeading)
          DesktopSectionHeader(title: '附近播放组', trailing: refresh)
        else
          Align(alignment: Alignment.centerRight, child: refresh),
        if (session.discoveredRooms.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 24),
            child: Text(
              '暂无附近播放组',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          )
        else
          for (final entry in session.discoveredRooms.indexed) ...[
            if (entry.$1 > 0) const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.$2.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${entry.$2.memberCount} 台 · ${entry.$2.locked ? '播放中' : '可加入'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed:
                            session.isConnected ||
                                session.isJoining ||
                                entry.$2.locked
                            ? null
                            : () => reportAction(
                                context,
                                () => _connect(
                                  entry.$2.address,
                                  port: entry.$2.port,
                                ),
                              ),
                        child: const Text('加入'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        if (!session.isConnected)
          DesktopActionButton(
            label: '输入地址加入',
            icon: Icons.link,
            onPressed: session.isJoining
                ? null
                : () => reportAction(context, () => _join(context)),
          ),
      ],
    );
  }

  Widget _mobilePage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final locked = [
      SessionPhase.preparing,
      SessionPhase.scheduled,
      SessionPhase.playing,
    ].contains(session.phase);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(title: '设备', subtitle: ''),
        const SizedBox(height: 24),
        MobileSection(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _mobileDeviceIcon(context, Icons.sensors, prominent: true),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.isConnected
                              ? (session.isMaster ? '我的播放组' : '已加入播放组')
                              : '一起聆听',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          session.isConnected
                              ? '${session.members.length} 台设备 · ${session.masterSelectionRequired
                                    ? '等待确认主控'
                                    : session.isMaster
                                    ? '本机主控'
                                    : '跟随主控'}'
                              : '连接同一 Wi-Fi 下的设备',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (session.isMaster || !session.isConnected) ...[
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: MobileActionButton(
                    label: session.isMaster ? '选择资源' : '创建播放组',
                    icon: session.isMaster
                        ? Icons.music_note_outlined
                        : Icons.add,
                    primary: true,
                    onPressed: session.isMaster
                        ? (session.canSelectResources ? selectLibrary : null)
                        : session.isJoining
                        ? null
                        : () => reportAction(context, _createRoom),
                  ),
                ),
              ],
              if (session.isJoining) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('等待主控接受')),
                    TextButton(
                      onPressed: () => reportAction(context, session.leave),
                      child: const Text('取消加入'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (session.masterSelectionRequired) ...[
          const SizedBox(height: 16),
          MobileSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MobileSectionHeader(title: '重新确认主控'),
                Text(
                  session.isMaster
                      ? '播放已停止。继续主控，或接受其他设备接管。'
                      : '播放已停止。等待主控确认，或申请接管。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                if (session.isMaster) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: MobileActionButton(
                      label: '继续由本机主控',
                      icon: Icons.check_circle_outline,
                      primary: true,
                      onPressed: () =>
                          reportAction(context, session.confirmMasterSelection),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (session.pendingJoins.isNotEmpty) ...[
          const SizedBox(height: 24),
          MobileSectionHeader(
            title: '加入申请',
            trailing: Text('${session.pendingJoins.length}'),
          ),
          ...session.pendingJoins.map(
            (request) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MobileSection(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      request.device.platform,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: MobileActionButton(
                            label: '拒绝',
                            icon: Icons.close,
                            onPressed: () => reportAction(
                              context,
                              () => session.rejectJoin(request.id),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: MobileActionButton(
                            label: '接受',
                            icon: Icons.check,
                            primary: true,
                            onPressed: locked
                                ? null
                                : () => reportAction(
                                    context,
                                    () => session.approveJoin(request.id),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (session.isMaster && session.takeoverRequester != null) ...[
          const SizedBox(height: 16),
          MobileSection(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MobileSectionHeader(title: '主控接管申请'),
                Text(
                  '${session.members.where((member) => member.id == session.takeoverRequester).map((member) => member.name).firstOrNull ?? '组内设备'}希望成为主控',
                ),
                const SizedBox(height: 5),
                Text(
                  '移交将结束当前播放。',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: MobileActionButton(
                        label: '拒绝',
                        icon: Icons.close,
                        onPressed: () =>
                            reportAction(context, session.rejectTakeover),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: MobileActionButton(
                        label: '移交主控',
                        icon: Icons.swap_horiz,
                        primary: true,
                        onPressed: () =>
                            reportAction(context, session.approveTakeover),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (session.isConnected) ...[
          MobileSectionHeader(
            title: '组内设备',
            trailing: Text(
              '${session.members.length} / 6',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
          MobileSection(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: _mobileMembers(context),
          ),
          const SizedBox(height: 24),
          if (session.isMaster) ...[
            MobileDisclosure(
              title: '连接地址',
              subtitle: locked ? '播放中，暂不接受新设备' : '供其他设备手动加入',
              icon: Icons.link,
              storageId: 'devices-mobile-addresses',
              children: [_mobileAddresses(context)],
            ),
            const SizedBox(height: 12),
          ],
          MobileDisclosure(
            title: '附近播放组',
            icon: Icons.radar,
            storageId: 'devices-mobile-nearby',
            children: [_mobileNearby(context)],
          ),
          const SizedBox(height: 24),
          if (!session.isMaster) ...[
            SizedBox(
              width: double.infinity,
              child: MobileActionButton(
                label: '申请成为主控',
                icon: Icons.swap_horiz,
                onPressed: session.takeoverRequester != null
                    ? null
                    : () => reportAction(context, session.requestTakeover),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: MobileActionButton(
              label: session.isMaster ? '解散播放组' : '退出播放组',
              icon: Icons.logout,
              destructive: true,
              onPressed: () => reportAction(context, session.leave),
            ),
          ),
        ] else ...[
          MobileSection(child: _mobileNearby(context)),
          const SizedBox(height: 16),
          MobileDisclosure(
            title: '本机输出',
            subtitle:
                '${channelName(session.localDevice.channel)} · ${session.localDevice.muted ? '已静音' : '${(session.localDevice.volume * 100).round()}%'}',
            icon: Icons.volume_up_outlined,
            storageId: 'devices-mobile-local-output',
            children: [_mobileMembers(context)],
          ),
        ],
      ],
    );
  }

  Widget _mobileDeviceIcon(
    BuildContext context,
    IconData icon, {
    bool prominent = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: prominent ? 48 : 40,
      height: prominent ? 48 : 40,
      decoration: BoxDecoration(
        color: prominent ? colors.primaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(prominent ? 15 : 12),
      ),
      child: Icon(
        icon,
        size: prominent ? 25 : 21,
        color: prominent ? colors.primary : colors.onSurfaceVariant,
      ),
    );
  }

  Widget _mobileMembers(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final members = session.isConnected
        ? session.members
        : [session.localDevice];
    return Column(
      children: [
        for (var i = 0; i < members.length; i++) ...[
          if (i > 0) const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                _mobileDeviceIcon(
                  context,
                  members[i].platform.toLowerCase().contains('android')
                      ? Icons.smartphone
                      : Icons.desktop_windows_outlined,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        members[i].name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${members[i].id == session.localDevice.id ? '本机 · ' : ''}${members[i].id == session.masterId ? '主控 · ' : ''}${channelName(members[i].channel)} · ${members[i].muted ? '已静音' : '${(members[i].volume * 100).round()}%'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '调整声道和音量',
                  onPressed:
                      session.isMaster ||
                          members[i].id == session.localDevice.id
                      ? () => showOutputDialog(context, session, members[i])
                      : null,
                  icon: Icon(
                    members[i].muted ? Icons.volume_off_outlined : Icons.tune,
                    size: 21,
                  ),
                ),
                if (session.isMaster && members[i].id != session.localDevice.id)
                  PopupMenuButton<String>(
                    tooltip: '管理设备',
                    onSelected: (_) => reportAction(
                      context,
                      () => session.removeMember(members[i].id),
                    ),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'remove', child: Text('移出播放组')),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _mobileNearby(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MobileSectionHeader(
          title: session.isConnected ? '可用播放组' : '附近播放组',
          trailing: IconButton(
            tooltip: '刷新附近播放组',
            onPressed: () => reportAction(context, session.restartDiscovery),
            icon: const Icon(Icons.refresh, size: 21),
          ),
        ),
        if (session.discoveredRooms.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 20),
            child: Text(
              '暂无附近播放组',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          )
        else
          ...session.discoveredRooms.map(
            (room) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  _mobileDeviceIcon(context, Icons.sensors),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${room.memberCount} 台 · ${room.locked ? '播放中' : '可加入'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(60, 48),
                    ),
                    onPressed:
                        session.isConnected || session.isJoining || room.locked
                        ? null
                        : () => reportAction(
                            context,
                            () => _connect(room.address, port: room.port),
                          ),
                    child: const Text('加入'),
                  ),
                ],
              ),
            ),
          ),
        if (!session.isConnected)
          SizedBox(
            width: double.infinity,
            child: MobileActionButton(
              label: '输入地址加入',
              icon: Icons.link,
              onPressed: session.isJoining
                  ? null
                  : () => reportAction(context, () => _join(context)),
            ),
          ),
      ],
    );
  }

  Widget _mobileAddresses(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (session.localAddresses.isEmpty)
        const Text('尚未获取局域网地址，请检查网络。')
      else
        ...session.localAddresses.map(
          (address) => Row(
            children: [
              Expanded(child: SelectableText('$address:${session.serverPort}')),
              IconButton(
                tooltip: '复制连接地址',
                icon: const Icon(Icons.copy_outlined, size: 20),
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: '$address:${session.serverPort}'),
                  );
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已复制连接地址。')));
                },
              ),
            ],
          ),
        ),
    ],
  );
}

String channelName(AudioChannel channel) => switch (channel) {
  AudioChannel.stereo => '完整音轨',
  AudioChannel.left => '左声道',
  AudioChannel.right => '右声道',
};

Future<void> showOutputDialog(
  BuildContext context,
  SessionController session,
  DeviceMember member,
) async {
  var volume = member.volume;
  var channel = member.channel;
  var muted = member.muted;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(member.name),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('声道'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: AudioChannel.values
                    .map(
                      (value) => ChoiceChip(
                        label: Text(channelName(value)),
                        selected: channel == value,
                        onSelected: (_) => setState(() => channel = value),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 22),
              Text('音量 ${(volume * 100).round()}%'),
              Slider(
                value: volume,
                onChanged: (value) => setState(() => volume = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('静音'),
                value: muted,
                onChanged: (value) => setState(() => muted = value),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await reportAction(
                context,
                () => session.setOutput(
                  deviceId: member.id,
                  volume: volume,
                  channel: channel,
                  muted: muted,
                ),
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('应用'),
          ),
        ],
      ),
    ),
  );
}
