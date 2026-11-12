import 'package:flutter/material.dart';

/// Compact layouts share one visual vocabulary across phone platforms.
bool isMobileLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 860;

class MobileSection extends StatelessWidget {
  const MobileSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class MobileSectionHeader extends StatelessWidget {
  const MobileSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.subtitle,
  });
  final String title;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 0, 3, 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

class MobileDisclosure extends StatelessWidget {
  const MobileDisclosure({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.children,
    required this.storageId,
    this.initiallyExpanded = false,
  });
  final String title, storageId;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MobileSection(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        // Never share the scroll view's storage key (a double) with this bool.
        key: PageStorageKey(storageId),
        initiallyExpanded: initiallyExpanded,
        maintainState: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: colors.onSurfaceVariant,
        collapsedIconColor: colors.onSurfaceVariant,
        textColor: colors.onSurface,
        collapsedTextColor: colors.onSurface,
        leading: icon == null ? null : Icon(icon, size: 21),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
        children: children,
      ),
    );
  }
}

class MobileActionButton extends StatelessWidget {
  const MobileActionButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.primary = false,
    this.destructive = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary, destructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = primary
        ? colors.primary
        : destructive
        ? colors.error.withValues(alpha: 0.07)
        : colors.primary.withValues(alpha: 0.07);
    final foreground = primary
        ? colors.onPrimary
        : destructive
        ? colors.error
        : colors.primary;
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        backgroundColor: background,
        foregroundColor: foreground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      icon: Icon(icon, size: 19),
      label: Text(label, textAlign: TextAlign.center),
    );
  }
}
