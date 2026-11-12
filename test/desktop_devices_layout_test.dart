import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/features/devices/devices_page.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio;

class _DesktopSession extends SessionController {
  _DesktopSession({this.connected = false, this.master = true})
    : super(
        audio: NoAudio(),
        deviceId: 'desktop',
        deviceName: '书房里的 Windows 电脑',
        platformName: 'Windows',
      );

  bool connected, master, locked = false;
  final actions = <String>[];
  List<JoinRequest> requests = [];

  static const peer = DeviceMember(
    id: 'phone',
    name: '客厅中一台名称比较长的安卓手机用于验证换行',
    platform: 'Android',
    address: '192.168.1.12',
    port: 19786,
    volume: 0.6,
    channel: AudioChannel.right,
  );

  @override
  bool get isConnected => connected;
  @override
  bool get isMaster => connected && master;
  @override
  String? get masterId => !connected
      ? null
      : master
      ? localDevice.id
      : peer.id;
  @override
  SessionPhase get phase => !connected
      ? SessionPhase.disconnected
      : locked
      ? SessionPhase.playing
      : SessionPhase.standby;
  @override
  List<DeviceMember> get members => connected ? [localDevice, peer] : [];
  @override
  List<JoinRequest> get pendingJoins => requests;
  @override
  List<String> get localAddresses => ['192.168.1.10'];
  @override
  int get serverPort => 19786;
  @override
  Future<void> createRoom() async {
    actions.add('create');
    connected = true;
    notifyListeners();
  }

  @override
  Future<void> leave({String? reason}) async {
    actions.add('leave');
    connected = false;
    notifyListeners();
  }

  @override
  void approveJoin(String id) => actions.add('approve:$id');
  @override
  void rejectJoin(String id, {String reason = '主控拒绝了加入申请'}) =>
      actions.add('reject:$id');
  @override
  void requestTakeover() => actions.add('takeover');

  void unlock() {
    locked = false;
    notifyListeners();
  }
}

Future<void> _showDesktopDevices(
  WidgetTester tester,
  _DesktopSession session, {
  double viewport = 1440,
  double contentWidth = 1120,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(viewport, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await session.shutdown();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: hemingTheme(scale > 1 ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          key: const PageStorageKey('desktop-devices-test-scroll'),
          padding: const EdgeInsets.all(28),
          child: Center(
            child: SizedBox(
              width: contentWidth,
              child: AnimatedBuilder(
                animation: session,
                builder: (context, _) => DevicesPage(
                  session: session,
                  beforeConnect: () async =>
                      session.actions.add('stop-preview'),
                  selectLibrary: () => session.actions.add('library'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final configuration in [
    (viewport: 900.0, content: 600.0, scale: 1.3),
    (viewport: 1440.0, content: 1120.0, scale: 1.0),
  ]) {
    for (final connected in [false, true]) {
      testWidgets(
        'desktop devices keep controls reachable at $configuration / $connected',
        (tester) async {
          final session = _DesktopSession(connected: connected);
          await _showDesktopDevices(
            tester,
            session,
            viewport: configuration.viewport,
            contentWidth: configuration.content,
            scale: configuration.scale,
          );
          expect(tester.takeException(), isNull);
          if (!connected) {
            await tester.ensureVisible(find.text('输入地址加入'));
            expect(find.text('输入地址加入').hitTestable(), findsOneWidget);
            await tester.ensureVisible(find.text('创建播放组'));
            await tester.tap(find.text('创建播放组'));
            await tester.pumpAndSettle();
            expect(session.actions, ['stop-preview', 'create']);
          }
          expect(find.text('192.168.1.10:19786'), findsOneWidget);
          expect(find.text(_DesktopSession.peer.name), findsOneWidget);
          await tester.ensureVisible(find.text('选择资源'));
          await tester.tap(find.text('选择资源'));
          expect(session.actions.last, 'library');
          await tester.ensureVisible(find.text('解散播放组'));
          await tester.tap(find.text('解散播放组'));
          await tester.pumpAndSettle();
          expect(session.actions.last, 'leave');
          expect(find.text('一起聆听'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'desktop approval remains disabled during playback while rejection works',
    (tester) async {
      final session = _DesktopSession(connected: true)..locked = true;
      session.requests = [
        JoinRequest(
          device: _DesktopSession.peer,
          receivedAt: DateTime(2026, 11, 12),
        ),
      ];
      await _showDesktopDevices(tester, session);
      final accept = find.ancestor(
        of: find.text('接受'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(tester.widget<FilledButton>(accept).onPressed, isNull);
      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(session.actions, ['reject:phone']);
      session.unlock();
      await tester.pumpAndSettle();
      await tester.tap(find.text('接受'));
      await tester.pumpAndSettle();
      expect(session.actions.last, 'approve:phone');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop follower can change only local output and request control',
    (tester) async {
      final session = _DesktopSession(connected: true, master: false);
      await _showDesktopDevices(tester, session);
      expect(find.text('选择资源'), findsNothing);
      expect(find.byTooltip('管理设备'), findsNothing);
      final outputs = tester
          .widgetList<IconButton>(find.byType(IconButton))
          .where((button) => button.tooltip == '调整声道和音量')
          .toList();
      expect(outputs[0].onPressed, isNotNull);
      expect(outputs[1].onPressed, isNull);
      await tester.tap(find.text('申请成为主控'));
      await tester.pumpAndSettle();
      expect(session.actions, ['takeover']);
      await tester.tap(find.text('退出播放组'));
      await tester.pumpAndSettle();
      expect(session.actions.last, 'leave');
      expect(tester.takeException(), isNull);
    },
  );
}
