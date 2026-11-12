enum SessionPhase { disconnected, standby, preparing, scheduled, playing }

enum AudioChannel { stereo, left, right }

enum PlaybackMode { sequential, random }

class PlayableTrack {
  const PlayableTrack({
    required this.id,
    required this.title,
    required this.path,
    required this.durationMs,
    this.isPlayable = true,
  });
  final String id;
  final String title;
  final String path;
  final int durationMs;
  final bool isPlayable;

  Map<String, Object?> toWire() => {
    'id': id,
    'title': title,
    'durationMs': durationMs,
  };
  factory PlayableTrack.fromWire(Map<String, dynamic> json) => PlayableTrack(
    id: json['id'] as String,
    title: json['title'] as String,
    path: '',
    durationMs: (json['durationMs'] as num).toInt(),
  );
}

class DeviceMember {
  const DeviceMember({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    this.volume = 1,
    this.channel = AudioChannel.stereo,
    this.muted = false,
  });
  final String id;
  final String name;
  final String platform;
  final String address;
  final int port;
  final double volume;
  final AudioChannel channel;
  final bool muted;

  DeviceMember copyWith({
    String? name,
    String? address,
    int? port,
    double? volume,
    AudioChannel? channel,
    bool? muted,
  }) => DeviceMember(
    id: id,
    name: name ?? this.name,
    platform: platform,
    address: address ?? this.address,
    port: port ?? this.port,
    volume: volume ?? this.volume,
    channel: channel ?? this.channel,
    muted: muted ?? this.muted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'address': address,
    'port': port,
    'volume': volume,
    'channel': channel.name,
    'muted': muted,
  };
  factory DeviceMember.fromJson(Map<String, dynamic> json) => DeviceMember(
    id: json['id'] as String,
    name: json['name'] as String,
    platform: json['platform'] as String,
    address: json['address'] as String,
    port: (json['port'] as num).toInt(),
    volume: (json['volume'] as num).toDouble().clamp(0, 1),
    channel: AudioChannel.values.byName(json['channel'] as String),
    muted: json['muted'] as bool,
  );
}

class JoinRequest {
  const JoinRequest({required this.device, required this.receivedAt});
  final DeviceMember device;
  final DateTime receivedAt;
  String get id => device.id;
  String get name => device.name;
}

class DiscoveredRoom {
  const DiscoveredRoom({
    required this.deviceId,
    required this.name,
    required this.address,
    required this.port,
    required this.memberCount,
    required this.locked,
    required this.lastSeen,
  });
  final String deviceId;
  final String name;
  final String address;
  final int port;
  final int memberCount;
  final bool locked;
  final DateTime lastSeen;
}
