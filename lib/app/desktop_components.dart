import 'package:flutter/material.dart';

/// Desktop surfaces share the mobile palette with denser desktop spacing.
class DesktopSection extends StatelessWidget {
  const DesktopSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class DesktopSectionHeader extends StatelessWidget {
  const DesktopSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    ),
  );
}

class DesktopColumns extends StatelessWidget {
  const DesktopColumns({
    super.key,
    required this.primary,
    required this.secondary,
    this.secondaryWidth = 300,
    this.breakpoint = 860,
  });
  final Widget primary, secondary;
  final double secondaryWidth, breakpoint;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => box.maxWidth < breakpoint
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [primary, const SizedBox(height: 24), secondary],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: primary),
              const SizedBox(width: 24),
              SizedBox(width: secondaryWidth, child: secondary),
            ],
          ),
  );
}

class DesktopDisclosure extends StatelessWidget {
  const DesktopDisclosure({
    super.key,
    required this.title,
    required this.storageId,
    required this.children,
    this.subtitle,
    this.icon,
    this.initiallyExpanded = false,
  });
  final String title, storageId;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) => DesktopSection(
    padding: EdgeInsets.zero,
    child: ExpansionTile(
      key: PageStorageKey(storageId),
      initiallyExpanded: initiallyExpanded,
      maintainState: true,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      tilePadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: icon == null ? null : Icon(icon, size: 20),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: subtitle == null ? null : Text(subtitle!),
      children: children,
    ),
  );
}

class DesktopActionButton extends StatelessWidget {
  const DesktopActionButton({
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
    final foreground = destructive ? colors.error : colors.primary;
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: primary
            ? colors.primary
            : foreground.withValues(alpha: 0.07),
        foregroundColor: primary ? colors.onPrimary : foreground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
