import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/networking/mdns_discovery.dart';

class _Interface implements NetworkInterface {
  _Interface(this.index, String ip) : addresses = [InternetAddress(ip)];
  @override
  final int index;
  @override
  final List<InternetAddress> addresses;
  @override
  String get name => 'wlan$index';
}

class _DiscoverySocket implements RawDatagramSocket {
  final events = StreamController<RawSocketEvent>.broadcast();
  final joins = <String>[], leaves = <String>[];
  final joined = <String>{}, rejected = <String>{};
  bool closed = false;
  String key(NetworkInterface? interface) =>
      '${interface!.index}/${interface.addresses.first.address}';
  @override
  set multicastHops(int value) {}
  @override
  set multicastLoopback(bool value) {}
  @override
  void setRawOption(RawSocketOption option) {}
  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed) throw const SocketException('closed');
    return buffer.length;
  }

  @override
  Datagram? receive() => null;
  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) {
    final id = key(interface);
    joins.add(id);
    if (closed || rejected.contains(id)) {
      throw const SocketException('adapter unavailable');
    }
    if (!joined.add(id)) throw StateError('duplicate membership');
  }

  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface]) {
    final id = key(interface);
    leaves.add(id);
    joined.remove(id);
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void close() {
    closed = true;
    joined.clear();
    unawaited(events.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'refresh uses current IPs and never rejoins unchanged interfaces',
    () async {
      var interfaces = <NetworkInterface>[_Interface(2, '192.168.1.104')];
      final socket = _DiscoverySocket();
      final discovery = MdnsDiscovery(
        deviceId: 'test',
        onChanged: () {},
        listInterfaces: () async => interfaces,
        bindSocket: () async => socket,
      );
      addTearDown(discovery.close);
      await discovery.start();
      await discovery.refresh();
      await discovery.refresh();
      expect(socket.joins, ['2/192.168.1.104']);
      interfaces = [_Interface(2, '192.168.1.105')];
      await discovery.refresh();
      expect(socket.leaves, ['2/192.168.1.104']);
      expect(socket.joined, {'2/192.168.1.105'});
      interfaces = [
        interfaces.first,
        interfaces.first,
        _Interface(3, '10.0.0.2'),
      ];
      await discovery.refresh();
      expect(socket.joins, [
        '2/192.168.1.104',
        '2/192.168.1.105',
        '3/10.0.0.2',
      ]);
      interfaces = [];
      await discovery.refresh();
      expect(socket.joined, isEmpty);
      expect(socket.leaves.length, 3);
    },
  );

  test(
    'only failed memberships retry; working interfaces are not duplicated',
    () async {
      final socket = _DiscoverySocket()..rejected.add('3/10.0.0.2');
      final discovery = MdnsDiscovery(
        deviceId: 'test',
        onChanged: () {},
        listInterfaces: () async => [
          _Interface(2, '192.168.1.104'),
          _Interface(3, '10.0.0.2'),
        ],
        bindSocket: () async => socket,
      );
      addTearDown(discovery.close);
      await discovery.start();
      await discovery.refresh();
      socket.rejected.clear();
      await discovery.refresh();
      await discovery.refresh();
      expect(socket.joins.where((id) => id == '2/192.168.1.104').length, 1);
      expect(socket.joins.where((id) => id == '3/10.0.0.2').length, 3);
      expect(socket.joined.length, 2);
    },
  );

  test(
    'resume restart replaces the socket and discards a pending old refresh',
    () async {
      var interfaces = <NetworkInterface>[_Interface(2, '192.168.1.104')];
      Completer<List<NetworkInterface>>? pending;
      final sockets = <_DiscoverySocket>[];
      final discovery = MdnsDiscovery(
        deviceId: 'test',
        onChanged: () {},
        listInterfaces: () => pending?.future ?? Future.value(interfaces),
        bindSocket: () async {
          final socket = _DiscoverySocket();
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(discovery.close);
      await discovery.start();
      pending = Completer<List<NetworkInterface>>();
      final oldRefresh = discovery.refresh();
      final restart = discovery.restart();
      final sameRestart = discovery.restart();
      expect(sockets.single.closed, isTrue);
      interfaces = [_Interface(2, '192.168.1.105')];
      pending.complete(interfaces);
      pending = null;
      await Future.wait([oldRefresh, restart, sameRestart]);
      expect(sockets.length, 2);
      expect(sockets.first.joins, ['2/192.168.1.104']);
      expect(sockets.last.joined, {'2/192.168.1.105'});
      expect(discovery.available, isTrue);
      await discovery.close();
      expect(sockets.every((socket) => socket.closed), isTrue);
      expect(discovery.available, isFalse);
    },
  );

  test(
    'closing during a pending bind cannot leak or resurrect discovery',
    () async {
      final binding = Completer<RawDatagramSocket>();
      final entered = Completer<void>();
      final discovery = MdnsDiscovery(
        deviceId: 'test',
        onChanged: () {},
        listInterfaces: () async => [_Interface(2, '192.168.1.104')],
        bindSocket: () {
          entered.complete();
          return binding.future;
        },
      );
      final starting = discovery.start();
      await entered.future;
      final closing = discovery.close();
      final socket = _DiscoverySocket();
      binding.complete(socket);
      await Future.wait([starting, closing]);
      expect(socket.closed, isTrue);
      expect(socket.joins, isEmpty);
      expect(discovery.available, isFalse);
    },
  );

  test('DNS-SD service query and records round trip including Unicode TXT', () {
    final query = DnsPacket.parse(DnsPacket.query(MdnsDiscovery.serviceType));
    expect(query.isResponse, isFalse);
    expect(query.questions, [MdnsDiscovery.serviceType]);
    final bytes = DnsPacket.response([
      DnsRecord(
        'room._heming._tcp.local',
        16,
        15,
        DnsPacket.textBytes({'name': '客厅音箱', 'id': 'test', 'v': '1'}),
      ),
    ]);
    final response = DnsPacket.parse(bytes);
    expect(response.isResponse, isTrue);
    expect(DnsPacket.readText(response.records.single.data)['name'], '客厅音箱');
  });

  test('DNS decoder rejects compression cycles and truncated records', () {
    final cyclic = Uint8List.fromList([
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
      0xc0,
      12,
      0,
      12,
      0,
      1,
    ]);
    expect(() => DnsPacket.parse(cyclic), throwsFormatException);
    final truncated = Uint8List.fromList([
      0,
      0,
      0x84,
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
    ]);
    expect(() => DnsPacket.parse(truncated), throwsFormatException);
    expect(
      () => DnsPacket.readText(Uint8List.fromList([8, 1, 2])),
      throwsFormatException,
    );
  });
}
