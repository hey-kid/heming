import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme_accent.dart';

/// A compact palette shared by the mobile and desktop appearance settings.
class ThemeColorPicker extends StatelessWidget {
  const ThemeColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final ThemeAccent selected;
  final ValueChanged<ThemeAccent> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '主题色',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            const gap = 8.0;
            final labelWidth = TextPainter(
              text: const TextSpan(text: '松柏绿', style: TextStyle(fontSize: 13)),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final minimumWidth = math.max(76.0, labelWidth.width + 24);
            labelWidth.dispose();
            final columns = ((box.maxWidth + gap) / (minimumWidth + gap))
                .floor()
                .clamp(1, ThemeAccent.values.length);
            final tileWidth = (box.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final accent in ThemeAccent.values)
                  SizedBox(
                    width: tileWidth,
                    child: _ColorOption(
                      accent: accent,
                      selected: selected == accent,
                      onPressed: () => onChanged(accent),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({
    required this.accent,
    required this.selected,
    required this.onPressed,
  });

  final ThemeAccent accent;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('theme-accent-${accent.name}'),
      label: accent.label,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 80),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          backgroundColor: selected
              ? colors.primaryContainer
              : colors.surfaceContainerLowest,
          foregroundColor: selected
              ? colors.onPrimaryContainer
              : colors.onSurface,
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 0.8,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.seed,
                ),
                child: selected
                    ? const Icon(Icons.check, color: Colors.white, size: 17)
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                accent.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
