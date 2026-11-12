import 'package:flutter/material.dart';
import '../../app/components.dart';
import '../../app/desktop_components.dart';
import '../../app/mobile_components.dart';
import '../../app/preferences.dart';
import '../../app/theme_color_picker.dart';
import '../../data/library_controller.dart';
import '../../session/session_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.session,
    required this.library,
    required this.preferences,
  });
  final SessionController session;
  final LibraryController library;
  final Preferences preferences;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.session.localDevice.name,
  );
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      isMobileLayout(context) ? _mobilePage(context) : _desktopPage(context);

  Widget _desktopPage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(title: '设置'),
        const SizedBox(height: 24),
        DesktopColumns(
          primary: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopSection(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const DesktopSectionHeader(title: '本机名称'),
                    LayoutBuilder(
                      builder: (context, box) {
                        final field = TextField(
                          controller: _name,
                          maxLength: 40,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            hintText: '例如：客厅电脑',
                            counterText: '',
                            prefixIcon: Icon(Icons.edit_outlined, size: 19),
                          ),
                        );
                        final save = DesktopActionButton(
                          label: '保存名称',
                          icon: Icons.check,
                          onPressed: () => _saveName(context),
                        );
                        if (box.maxWidth < 420 ||
                            MediaQuery.textScalerOf(context).scale(14) > 20) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [field, const SizedBox(height: 12), save],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: field),
                            const SizedBox(width: 12),
                            save,
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              DesktopSection(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const DesktopSectionHeader(title: '外观'),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            icon: Icon(
                              Icons.brightness_auto_outlined,
                              size: 18,
                            ),
                            label: Text('跟随系统'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_outlined, size: 18),
                            label: Text('浅色'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_outlined, size: 18),
                            label: Text('深色'),
                          ),
                        ],
                        selected: {widget.preferences.themeMode},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) =>
                            widget.preferences.setTheme(value.first),
                        style: ButtonStyle(
                          minimumSize: const WidgetStatePropertyAll(
                            Size(0, 44),
                          ),
                          padding: const WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 10),
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
                    ),
                    const SizedBox(height: 22),
                    ThemeColorPicker(
                      selected: widget.preferences.themeAccent,
                      onChanged: widget.preferences.setThemeAccent,
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
                title: '资源与播放',
                icon: Icons.tune,
                storageId: 'settings-desktop-playback-information',
                children: [
                  _informationRow(context, '播放格式', 'FLAC'),
                  const Divider(),
                  _informationRow(context, '音频规格', '48 kHz · 16-bit · 双声道'),
                  const Divider(),
                  _informationRow(context, '目标缓冲', '5 秒'),
                  const Divider(),
                  _informationRow(context, '播放组容量', '最多 6 台设备'),
                  const SizedBox(height: 14),
                  Text(
                    '回到桌面或锁屏后继续播放。其他应用占用音频时，本机临时降音或静音，进度与连接保持。系统休眠或音频输出设备变化时停止播放。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              DesktopSection(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const DesktopSectionHeader(title: '关于'),
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.graphic_eq,
                            size: 24,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '和鸣',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Windows / Android',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '局域网内，共享一段声音。',
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
        ),
      ],
    );
  }

  Future<void> _saveName(BuildContext context) => reportAction(context, () {
    final name = _name.text.trim();
    if (name.isEmpty) throw const FormatException('设备名称不能为空。');
    widget.session.rename(name);
    widget.library.repository.setSetting('deviceName', name);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('设备名称已保存。')));
  });

  Widget _mobilePage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeading(title: '设置', subtitle: ''),
        const SizedBox(height: 24),
        const MobileSectionHeader(title: '本机名称'),
        MobileSection(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                maxLength: 40,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: '例如：客厅手机',
                  counterText: '',
                  prefixIcon: Icon(Icons.edit_outlined, size: 20),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: MobileActionButton(
                  label: '保存名称',
                  icon: Icons.check,
                  onPressed: () => _saveName(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const MobileSectionHeader(title: '外观'),
        MobileSection(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final entry in [
                (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
                (ThemeMode.light, '浅色', Icons.light_mode_outlined),
                (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
              ].indexed) ...[
                if (entry.$1 > 0)
                  const Padding(
                    padding: EdgeInsets.only(left: 56, right: 18),
                    child: Divider(),
                  ),
                _themeRow(
                  context,
                  mode: entry.$2.$1,
                  label: entry.$2.$2,
                  icon: entry.$2.$3,
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                child: Divider(),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: ThemeColorPicker(
                  selected: widget.preferences.themeAccent,
                  onChanged: widget.preferences.setThemeAccent,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        MobileDisclosure(
          title: '资源与播放',
          icon: Icons.tune,
          storageId: 'settings-mobile-playback-information',
          children: [
            _informationRow(context, '播放格式', 'FLAC'),
            const Divider(),
            _informationRow(context, '音频规格', '48 kHz · 16-bit · 双声道'),
            const Divider(),
            _informationRow(context, '目标缓冲', '5 秒'),
            const Divider(),
            _informationRow(context, '播放组容量', '最多 6 台设备'),
            const SizedBox(height: 14),
            Text(
              '回到桌面或锁屏后继续播放。其他应用占用音频时，本机临时降音或静音，进度与连接保持。系统休眠或音频输出设备变化时停止播放。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const MobileSectionHeader(title: '关于'),
        MobileSection(
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(Icons.graphic_eq, color: colors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('和鸣', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Windows / Android',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '局域网内，共享一段声音。',
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
        ),
      ],
    );
  }

  Widget _themeRow(
    BuildContext context, {
    required ThemeMode mode,
    required String label,
    required IconData icon,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.preferences.themeMode == mode;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        onTap: () => widget.preferences.setTheme(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Icon(icon, size: 21, color: colors.onSurfaceVariant),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 12),
                Icon(Icons.check, size: 21, color: colors.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _informationRow(BuildContext context, String label, String value) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: colors.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(value, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
