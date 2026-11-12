import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../shared/models.dart';

/// DNS-SD on the local link, using _heming._tcp.local (RFC 6762/6763).
/// A stable, random device ID makes the advertised instance/host names unique.
/// Manual IP joining remains available when multicast is blocked by the network.
class MdnsDiscovery {
  MdnsDiscovery({
    required this.deviceId,
    required this.onChanged,
    Future<List<NetworkInterface>> Function()? listInterfaces,
    Future<RawDatagramSocket> Function()? bindSocket,
  }) : _listInterfaces = listInterfaces ?? _defaultInterfaces,
       _bindSocket = bindSocket ?? _defaultSocket;
  static Future<List<NetworkInterface>> _defaultInterfaces() =>
      NetworkInterface.list(type: InternetAddressType.IPv4);
  static Future<RawDatagramSocket> _defaultSocket() =>
      RawDatagramSocket.bind(InternetAddress.anyIPv4, 5353, reuseAddress: true);
  static const serviceType = '_heming._tcp.local';
  static final _group = InternetAddress('224.0.0.251');
  final String deviceId;
  final void Function() onChanged;
  final Future<List<NetworkInterface>> Function() _listInterfaces;
  final Future<RawDatagramSocket> Function() _bindSocket;
  final Map<String, DiscoveredRoom> _rooms = {};
  RawDatagramSocket? _socket;
  Timer? _timer;
  List<NetworkInterface> _interfaces = [];
  final Map<String, NetworkInterface> _joined = {};
  Future<void>? _starting, _refreshing, _restarting;
  int _generation = 0;
  DeviceMember? _advertised;
  int _count = 1;
  bool _locked = false;
  DateTime? _lastAnnouncement;
  bool get available => _socket != null;
  List<DiscoveredRoom> get rooms => List.unmodifiable(_rooms.values);

  Future<void> start() {
    if (_socket != null) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    final generation = ++_generation;
    try {
      final interfaces = await _listInterfaces();
      if (generation != _generation) return;
      final socket = await _bindSocket();
      if (generation != _generation) {
        socket.close();
        return;
      }
      _socket = socket;
      socket.multicastHops = 255;
      socket.multicastLoopback = false;
      _updateInterfaces(socket, interfaces);
      socket.listen(
        (event) {
          if (socket != _socket || event != RawSocketEvent.read) return;
          Datagram? datagram;
          while ((datagram = socket.receive()) != null) {
            _receive(datagram!);
          }
        },
        onError: (Object _) {
          /* Manual addressing is still usable. */
        },
        onDone: () {
          if (_socket == socket) {
            _socket = null;
            _joined.clear();
            onChanged();
          }
        },
      );
      _queryAndAnnounce();
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        final before = _rooms.length;
        final now = DateTime.now();
        _rooms.removeWhere(
          (_, room) =>
              now.difference(room.lastSeen) > const Duration(seconds: 16),
        );
        if (before != _rooms.length) onChanged();
        unawaited(refresh());
      });
    } catch (_) {
      // Discovery is optional: Windows/VPN adapters can reject individual
      // multicast socket options. Manual IP joining must still boot normally.
      if (generation == _generation) {
        _socket?.close();
        _socket = null;
        _joined.clear();
      }
    }
  }

  void advertise(
    DeviceMember? device, {
    int memberCount = 1,
    bool locked = false,
  }) {
    if (_advertised != null && device == null) _announce(ttl: 0);
    final changed =
        _advertised?.name != device?.name ||
        _advertised?.port != device?.port ||
        _count != memberCount ||
        _locked != locked;
    _advertised = device;
    _count = memberCount;
    _locked = locked;
    if (device != null && changed) _announce();
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    final socket = _socket;
    if (socket == null) {
      await start();
      return;
    }
    final generation = _generation;
    try {
      final interfaces = await _listInterfaces();
      if (socket != _socket || generation != _generation) return;
      _updateInterfaces(socket, interfaces);
    } catch (_) {
      // Keep usable existing adapters if enumeration temporarily fails.
    }
    if (socket == _socket && generation == _generation) _queryAndAnnounce();
  }

  void _updateInterfaces(
    RawDatagramSocket socket,
    List<NetworkInterface> interfaces,
  ) {
    final current = <String, NetworkInterface>{};
    for (final interface in interfaces) {
      final address = interface.addresses
          .where((a) => a.type == InternetAddressType.IPv4)
          .firstOrNull;
      if (address != null) {
        current['${interface.index}/${address.address}'] = interface;
      }
    }
    for (final key
        in _joined.keys.where((key) => !current.containsKey(key)).toList()) {
      try {
        socket.leaveMulticast(_group, _joined[key]);
      } catch (_) {
        // The OS may already have removed membership with a disconnected NIC.
      }
      _joined.remove(key);
    }
    for (final entry in current.entries) {
      if (_joined.containsKey(entry.key)) continue;
      try {
        socket.joinMulticast(_group, entry.value);
        _joined[entry.key] = entry.value;
      } catch (_) {
        /* Retry only this failed adapter on a later refresh. */
      }
    }
    _interfaces = current.values.toList();
  }

  void _queryAndAnnounce() {
    _send(DnsPacket.query(serviceType));
    if (_advertised != null) _announce();
  }

  /// Resume can invalidate Android multicast membership without changing its
  /// interface address. Rebinding refreshes membership without touching the
  /// independent control server, room membership or native playback.
  Future<void> restart() =>
      _restarting ??= _restart().whenComplete(() => _restarting = null);

  Future<void> _restart() async {
    final pending = [?_starting, ?_refreshing];
    _closeSocket(clearRooms: false);
    final generation = _generation;
    await Future.wait(pending);
    if (generation != _generation) return;
    await start();
    onChanged();
  }

  void _send(Uint8List bytes) {
    final socket = _socket;
    if (socket == null) return;
    for (final interface in _interfaces) {
      try {
        final address = interface.addresses.firstWhere(
          (a) => a.type == InternetAddressType.IPv4,
        );
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            address.rawAddress,
          ),
        );
        socket.send(bytes, _group, 5353);
      } catch (_) {
        /* Continue with the other interfaces. */
      }
    }
  }

  void _announce({int ttl = 15}) {
    final device = _advertised;
    if (device == null) return;
    final instance = 'heming-$deviceId.$serviceType';
    final host = 'heming-$deviceId.local';
    final records = <DnsRecord>[
      DnsRecord(serviceType, 12, ttl, DnsPacket.nameBytes(instance)),
      DnsRecord(
        instance,
        33,
        ttl,
        Uint8List.fromList([
          0,
          0,
          0,
          0,
          device.port >> 8,
          device.port & 255,
          ...DnsPacket.nameBytes(host),
        ]),
      ),
      DnsRecord(
        instance,
        16,
        ttl,
        DnsPacket.textBytes({
          'v': '1',
          'id': deviceId,
          'name': device.name,
          'members': '$_count',
          'locked': _locked ? '1' : '0',
        }),
      ),
      for (final interface in _interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback) DnsRecord(host, 1, ttl, address.rawAddress),
    ];
    _send(DnsPacket.response(records));
    _lastAnnouncement = DateTime.now();
  }

  void _receive(Datagram datagram) {
    try {
      final packet = DnsPacket.parse(datagram.data);
      if (!packet.isResponse) {
        if (_advertised != null &&
            packet.questions.any(
              (q) => q == serviceType || q == 'heming-$deviceId.$serviceType',
            ) &&
            (_lastAnnouncement == null ||
                DateTime.now().difference(_lastAnnouncement!) >
                    const Duration(milliseconds: 250))) {
          _announce();
        }
        return;
      }
      for (final txt in packet.records.where(
        (r) => r.type == 16 && r.name.endsWith('.$serviceType'),
      )) {
        final fields = DnsPacket.readText(txt.data);
        final id = fields['id'];
        if (fields['v'] != '1' ||
            id == null ||
            id == deviceId ||
            id.length > 128) {
          continue;
        }
        final srv = packet.records
            .where((r) => r.type == 33 && r.name == txt.name)
            .firstOrNull;
        if (srv == null || srv.data.length < 6) continue;
        final port = (srv.data[4] << 8) | srv.data[5];
        if (port == 0) continue;
        if (txt.ttl == 0) {
          _rooms.remove(id);
        } else {
          _rooms[id] = DiscoveredRoom(
            deviceId: id,
            name: fields['name'] ?? '和鸣设备',
            address: datagram.address.address,
            port: port,
            memberCount:
                int.tryParse(fields['members'] ?? '')?.clamp(1, 6) ?? 1,
            locked: fields['locked'] == '1',
            lastSeen: DateTime.now(),
          );
        }
        onChanged();
      }
    } on FormatException {
      /* Ignore unrelated or malformed LAN traffic. */
    } on RangeError {
      /* Reject a truncated datagram. */
    }
  }

  void _closeSocket({required bool clearRooms}) {
    ++_generation;
    _timer?.cancel();
    final socket = _socket;
    _socket = null;
    socket?.close();
    _joined.clear();
    _interfaces = [];
    if (clearRooms) _rooms.clear();
  }

  Future<void> close() async {
    _announce(ttl: 0);
    _closeSocket(clearRooms: true);
    await Future.wait([?_starting, ?_refreshing, ?_restarting]);
  }
}

class DnsRecord {
  const DnsRecord(this.name, this.type, this.ttl, this.data);
  final String name;
  final int type;
  final int ttl;
  final Uint8List data;
}

/// Small defensive codec; no compression is emitted, compressed names are read.
class DnsPacket {
  DnsPacket({
    required this.isResponse,
    required this.questions,
    required this.records,
  });
  final bool isResponse;
  final List<String> questions;
  final List<DnsRecord> records;

  static Uint8List nameBytes(String name) {
    final result = BytesBuilder();
    for (final label in name.split('.').where((s) => s.isNotEmpty)) {
      final bytes = utf8.encode(label);
      if (bytes.length > 63) throw const FormatException('DNS label too long');
      result.addByte(bytes.length);
      result.add(bytes);
    }
    result.addByte(0);
    return result.takeBytes();
  }

  static Uint8List textBytes(Map<String, String> fields) {
    final result = BytesBuilder();
    for (final field in fields.entries) {
      final bytes = utf8.encode('${field.key}=${field.value}');
      if (bytes.length > 255) throw const FormatException('DNS TXT too long');
      result.addByte(bytes.length);
      result.add(bytes);
    }
    return result.takeBytes();
  }

  static Map<String, String> readText(Uint8List data) {
    final fields = <String, String>{};
    var offset = 0;
    while (offset < data.length) {
      final length = data[offset++];
      if (offset + length > data.length) {
        throw const FormatException('Truncated TXT');
      }
      final text = utf8.decode(
        data.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      final split = text.indexOf('=');
      if (split > 0) {
        fields[text.substring(0, split)] = text.substring(split + 1);
      }
    }
    return fields;
  }

  static Uint8List query(String name) => Uint8List.fromList([
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    ...nameBytes(name),
    0,
    12,
    0,
    1,
  ]);

  static Uint8List response(List<DnsRecord> records) {
    final bytes = BytesBuilder()
      ..add([
        0,
        0,
        0x84,
        0,
        0,
        0,
        records.length >> 8,
        records.length & 255,
        0,
        0,
        0,
        0,
      ]);
    for (final record in records) {
      bytes.add(nameBytes(record.name));
      final header = ByteData(10)
        ..setUint16(0, record.type)
        ..setUint16(2, record.type == 12 ? 1 : 0x8001)
        ..setUint32(4, record.ttl)
        ..setUint16(8, record.data.length);
      bytes.add(header.buffer.asUint8List());
      bytes.add(record.data);
    }
    return bytes.takeBytes();
  }

  static DnsPacket parse(Uint8List bytes) {
    if (bytes.length < 12 || bytes.length > 9000) {
      throw const FormatException('Invalid DNS length');
    }
    final data = ByteData.sublistView(bytes);
    var offset = 12;
    String readName() {
      final result = <String>[];
      var cursor = offset;
      var jumped = false;
      final visited = <int>{};
      for (var labels = 0; labels < 128; labels++) {
        if (cursor >= bytes.length || !visited.add(cursor)) {
          throw const FormatException('Invalid DNS pointer');
        }
        final size = bytes[cursor++];
        if (size == 0) {
          if (!jumped) offset = cursor;
          return result.join('.').toLowerCase();
        }
        if ((size & 0xc0) == 0xc0) {
          if (cursor >= bytes.length) {
            throw const FormatException('Truncated DNS pointer');
          }
          final target = ((size & 0x3f) << 8) | bytes[cursor++];
          if (!jumped) offset = cursor;
          jumped = true;
          cursor = target;
        } else {
          if (size > 63 || cursor + size > bytes.length) {
            throw const FormatException('Invalid DNS label');
          }
          result.add(
            utf8.decode(
              bytes.sublist(cursor, cursor + size),
              allowMalformed: true,
            ),
          );
          cursor += size;
        }
      }
      throw const FormatException('DNS name too long');
    }

    final questions = <String>[];
    final records = <DnsRecord>[];
    final questionCount = data.getUint16(4);
    final recordCount =
        data.getUint16(6) + data.getUint16(8) + data.getUint16(10);
    if (questionCount + recordCount > 256) {
      throw const FormatException('Too many records');
    }
    for (var i = 0; i < questionCount; i++) {
      questions.add(readName());
      offset += 4;
      if (offset > bytes.length) {
        throw const FormatException('Truncated question');
      }
    }
    for (var i = 0; i < recordCount; i++) {
      final name = readName();
      if (offset + 10 > bytes.length) {
        throw const FormatException('Truncated record');
      }
      final type = data.getUint16(offset);
      final ttl = data.getUint32(offset + 4);
      final length = data.getUint16(offset + 8);
      offset += 10;
      if (offset + length > bytes.length) {
        throw const FormatException('Truncated rdata');
      }
      records.add(
        DnsRecord(
          name,
          type,
          ttl,
          Uint8List.sublistView(bytes, offset, offset + length),
        ),
      );
      offset += length;
    }
    return DnsPacket(
      isResponse: (data.getUint16(2) & 0x8000) != 0,
      questions: questions,
      records: records,
    );
  }
}
