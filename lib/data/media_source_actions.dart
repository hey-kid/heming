import 'package:flutter/services.dart';

import 'media_scan.dart';

/// Opens the original source with a system app, without copying or importing it.
/// Native implementations validate the path/URI and grant read-only access.
class MediaSourceActions {
  const MediaSourceActions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('heming_media_scan');

  final MethodChannel _channel;

  Future<void> open(MediaScanEntry entry) => _invoke('openMedia', entry);

  /// Windows only. The native shell selects the existing file in its folder.
  Future<void> reveal(MediaScanEntry entry) => _invoke('revealMedia', entry);

  Future<void> _invoke(String method, MediaScanEntry entry) async {
    if (!const {'audio', 'video'}.contains(entry.category) ||
        entry.locator.isEmpty ||
        entry.locator.contains('\u0000')) {
      throw const FormatException('无法打开此媒体来源，请刷新列表。');
    }
    await _channel.invokeMethod<void>(method, {'locator': entry.locator});
  }
}
