import 'package:flutter/material.dart';

import '../../app/components.dart';
import '../../data/media_scan.dart';
import '../../preview/preview_controller.dart';
import '../../preview/scan_preview_controller.dart';

/// One foreground preview, kept separate from selection and library import.
class ScanPreviewStrip extends StatefulWidget {
  const ScanPreviewStrip({
    super.key,
    required this.controller,
    required this.enabled,
    this.compact = false,
    this.onOpenExternally,
  });

  final ScanPreviewController controller;
  final bool enabled, compact;
  final Future<void> Function(MediaScanEntry)? onOpenExternally;

  @override
  State<ScanPreviewStrip> createState() => _ScanPreviewStripState();
}

class _ScanPreviewStripState extends State<ScanPreviewStrip> {
  String? _entryId;
  double? _seekPosition;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final preview = widget.controller;
      final entry = preview.entry;
      if (entry == null || !preview.isActive) return const SizedBox.shrink();
      if (_entryId != entry.sourceId) {
        _entryId = entry.sourceId;
        _seekPosition = null;
      }
      final colors = Theme.of(context).colorScheme;
      final loading = preview.state == PreviewState.loading;
      final failed = preview.state == PreviewState.failed;
      final replay = failed || preview.state == PreviewState.completed;
      final playing = preview.state == PreviewState.playing;
      final duration = preview.durationMs;
      final position = (_seekPosition ?? preview.positionMs.toDouble())
          .clamp(0, duration > 0 ? duration : 0)
          .toDouble();
      return Container(
        key: const ValueKey('scan-preview-strip'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  key: const ValueKey('scan-preview-toggle'),
                  tooltip: replay
                      ? '重新试听'
                      : playing
                      ? '暂停试听'
                      : '继续试听',
                  onPressed: !widget.enabled || loading
                      ? null
                      : () => reportAction(
                          context,
                          () => replay
                              ? preview.play(entry)
                              : preview.togglePause(),
                        ),
                  icon: loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        loading
                            ? '正在准备试听…'
                            : failed
                            ? '暂时无法试听'
                            : '${_duration(position.round())} / ${_duration(duration)}',
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
                IconButton(
                  key: const ValueKey('scan-preview-close'),
                  tooltip: '关闭试听',
                  onPressed: () => reportAction(context, preview.stop),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            if (!widget.compact && !failed)
              SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 2),
                child: Slider(
                  key: const ValueKey('scan-preview-seek'),
                  value: position,
                  max: duration > 0 ? duration.toDouble() : 1,
                  semanticFormatterCallback: (value) =>
                      _duration(value.round()),
                  onChanged: !widget.enabled || loading || duration <= 0
                      ? null
                      : (value) => setState(() => _seekPosition = value),
                  onChangeEnd: !widget.enabled || loading || duration <= 0
                      ? null
                      : (value) {
                          setState(() => _seekPosition = null);
                          reportAction(
                            context,
                            () => preview.seek(value.round()),
                          );
                        },
                ),
              ),
            if (!widget.compact && failed) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  preview.error ?? '此格式暂时无法试听，可以使用其他播放器打开。',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (widget.onOpenExternally != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => widget.onOpenExternally!(entry),
                    child: const Text('用其他播放器打开'),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );

  static String _duration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
