enum LibraryStatus {
  checking,
  needsConversion,
  queued,
  converting,
  ready,
  failed,
  unavailable,
}

class AudioMetadata {
  const AudioMetadata({
    required this.codec,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.durationMs,
    this.verified = false,
  });
  final String codec;
  final int sampleRate, channels, bitsPerSample, durationMs;
  final bool verified;
  bool get isCanonical =>
      codec.toLowerCase() == 'flac' &&
      sampleRate == 48000 &&
      channels == 2 &&
      bitsPerSample == 16;
  Map<String, Object?> toJson() => {
    'codec': codec,
    'sampleRate': sampleRate,
    'channels': channels,
    'bitsPerSample': bitsPerSample,
    'durationMs': durationMs,
    'verified': verified,
  };
  factory AudioMetadata.fromJson(Map<String, dynamic> value) => AudioMetadata(
    codec: value['codec'] as String? ?? 'unknown',
    sampleRate: value['sampleRate'] as int? ?? 0,
    channels: value['channels'] as int? ?? 0,
    bitsPerSample: value['bitsPerSample'] as int? ?? 0,
    durationMs: value['durationMs'] as int? ?? 0,
    verified: value['verified'] == true,
  );
}

class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.title,
    required this.originalPath,
    required this.originalName,
    required this.status,
    required this.importedAt,
    this.category = 'audio',
    this.playablePath,
    this.metadata,
    this.error,
    this.groupId,
    this.groupOrder = 0,
    this.sourceKeys = const [],
    this.contentHash,
    this.originalSize,
    this.originalModifiedMs,
  });
  final String id, title, originalPath, originalName, category;
  final String? playablePath, error;
  final String? groupId;
  final int groupOrder;
  final List<String> sourceKeys;
  final String? contentHash;
  final int? originalSize, originalModifiedMs;
  final LibraryStatus status;
  final DateTime importedAt;
  final AudioMetadata? metadata;
  bool get isPlayable => status == LibraryStatus.ready && playablePath != null;
  int get durationMs => metadata?.durationMs ?? 0;

  LibraryItem copyWith({
    LibraryStatus? status,
    String? playablePath,
    AudioMetadata? metadata,
    String? error,
    bool clearError = false,
    bool clearPlayable = false,
    String? groupId,
    int? groupOrder,
    bool clearGroup = false,
    List<String>? sourceKeys,
    String? contentHash,
    int? originalSize,
    int? originalModifiedMs,
  }) => LibraryItem(
    id: id,
    title: title,
    originalPath: originalPath,
    originalName: originalName,
    category: category,
    importedAt: importedAt,
    status: status ?? this.status,
    playablePath: clearPlayable ? null : playablePath ?? this.playablePath,
    metadata: metadata ?? this.metadata,
    error: clearError ? null : error ?? this.error,
    groupId: clearGroup ? null : groupId ?? this.groupId,
    groupOrder: groupOrder ?? this.groupOrder,
    sourceKeys: sourceKeys ?? this.sourceKeys,
    contentHash: contentHash ?? this.contentHash,
    originalSize: originalSize ?? this.originalSize,
    originalModifiedMs: originalModifiedMs ?? this.originalModifiedMs,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'originalPath': originalPath,
    'originalName': originalName,
    'category': category,
    'status': status.name,
    'importedAt': importedAt.toIso8601String(),
    'playablePath': playablePath,
    'metadata': metadata?.toJson(),
    'error': error,
    'groupId': groupId,
    'groupOrder': groupOrder,
    'sourceKeys': sourceKeys,
    'contentHash': contentHash,
    'originalSize': originalSize,
    'originalModifiedMs': originalModifiedMs,
  };
  factory LibraryItem.fromJson(Map<String, dynamic> value) => LibraryItem(
    id: value['id'] as String,
    title: value['title'] as String,
    originalPath: value['originalPath'] as String,
    originalName: value['originalName'] as String,
    category: value['category'] as String? ?? 'audio',
    status: LibraryStatus.values.firstWhere(
      (status) => status.name == value['status'],
      orElse: () => LibraryStatus.unavailable,
    ),
    importedAt: DateTime.parse(value['importedAt'] as String),
    playablePath: value['playablePath'] as String?,
    metadata: value['metadata'] is Map
        ? AudioMetadata.fromJson(
            Map<String, dynamic>.from(value['metadata'] as Map),
          )
        : null,
    error: value['error'] as String?,
    groupId: value['groupId'] as String?,
    groupOrder: value['groupOrder'] as int? ?? 0,
    sourceKeys:
        (value['sourceKeys'] as List?)?.whereType<String>().toList() ??
        const [],
    contentHash: value['contentHash'] as String?,
    originalSize: value['originalSize'] as int?,
    originalModifiedMs: value['originalModifiedMs'] as int?,
  );
}

class LibraryGroup {
  const LibraryGroup({
    required this.id,
    required this.name,
    this.sortOrder = 0,
  });
  final String id, name;
  final int sortOrder;

  LibraryGroup copyWith({String? name}) =>
      LibraryGroup(id: id, name: name ?? this.name, sortOrder: sortOrder);
}

class ConversionCancelled implements Exception {
  const ConversionCancelled();
}

class ConversionToken {
  bool isCancelled = false;
  void Function()? onCancel;
  void cancel() {
    isCancelled = true;
    onCancel?.call();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const ConversionCancelled();
  }
}

abstract interface class MediaBackend {
  Future<AudioMetadata> inspect(String path, {bool verifyDecode = false});
  Future<void> convert(
    String inputPath,
    String outputPath,
    ConversionToken token,
    void Function(double) onProgress,
  );
}
