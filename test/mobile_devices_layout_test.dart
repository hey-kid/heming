import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/features/devices/devices_page.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio;

class _MobileSession extends SessionController {
  _MobileSession({this.connected = false})
    : super(
        audio: NoAudio(),
        deviceId: 'phone',
        deviceName: '客厅里的安卓手机',
        platformName: 'Android',
      );

  bool connected;
  final actions = <String>[];

  @override
  bool get isConnected => connected;
  @override
  bool get isMaster => connected;
  @override
  String? get masterId => connected ? localDevice.id : null;
  @override
  SessionPhase get phase =>
      connected ? SessionPhase.standby : SessionPhase.disconnected;
  @override
  int get serverPort => 19786;
  @override
  List<String> get localAddresses => ['192.168.1.104'];
  @override
  List<DeviceMember> get members => connected
      ? [
          localDevice,
          const DeviceMember(
            id: 'computer',
            name: '一个很长的电脑设备名称用于检查窄屏列表中的操作按钮',
            platform: 'Windows',
            address: '192.168.1.103',
            port: 19786,
            volume: 0.6,
            channel: AudioChannel.right,
          ),
        ]
      : [];

  @override
  Future<void> createRoom() async {
    actions.add('create');
    connected = true;
    notifyListeners();
  }

  @override
  Future<void> join(String host, {int port = 19786}) async {
    actions.add('join:$host:$port');
  }

  @override
  Future<void> leave({String? reason}) async {
    actions.add('leave');
    connected = false;
    notifyListeners();
  }
}

Future<void> _showDevices(
  WidgetTester tester,
  _MobileSession session, {
  required double width,
  required double scale,
  required Brightness brightness,
}) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await session.shutdown();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: hemingTheme(brightness, mobile: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          key: const PageStorageKey('mobile-devices-test-scroll'),
          padding: const EdgeInsets.all(16),
          child: AnimatedBuilder(
            animation: session,
            builder: (context, _) => DevicesPage(
              session: session,
              beforeConnect: () async => session.actions.add('stop-preview'),
              selectLibrary: () => session.actions.add('library'),
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
    (width: 360.0, scale: 1.15, brightness: Brightness.light),
    (width: 320.0, scale: 1.4, brightness: Brightness.dark),
  ]) {
    for (final connected in [false, true]) {
      testWidgets(
        'devices fit ${configuration.width}px at ${configuration.scale}x; connected=$connected',
        (tester) async {
          final session = _MobileSession(connected: connected);
          await _showDevices(
            tester,
            session,
            width: configuration.width,
            scale: configuration.scale,
            brightness: configuration.brightness,
          );
          expect(tester.takeException(), isNull);

          if (connected) {
            expect(
              tester.getTopLeft(find.text('选择资源')).dy,
              lessThan(tester.getTopLeft(find.text('组内设备')).dy),
            );
            // Addresses stay out of the main flow until deliberately opened.
            expect(find.text('192.168.1.104:19786'), findsNothing);
            await tester.ensureVisible(find.text('连接地址'));
            await tester.tap(find.text('连接地址'));
            await tester.pumpAndSettle();
            expect(find.text('192.168.1.104:19786'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.ensureVisible(find.text('解散播放组'));
            expect(find.text('解散播放组').hitTestable(), findsOneWidget);
          } else {
            expect(
              tester.getTopLeft(find.text('创建播放组')).dy,
              lessThan(tester.getTopLeft(find.text('附近播放组')).dy),
            );
            expect(find.text(session.localDevice.name), findsNothing);
            await tester.ensureVisible(find.text('输入地址加入'));
            expect(find.text('输入地址加入').hitTestable(), findsOneWidget);
            await tester.ensureVisible(find.text('本机输出'));
            await tester.tap(find.text('本机输出'));
            await tester.pumpAndSettle();
            expect(find.text(session.localDevice.name), findsOneWidget);
            expect(find.byTooltip('调整声道和音量'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('mobile create, choose music and leave keep their actions', (
    tester,
  ) async {
    final session = _MobileSession();
    await _showDevices(
      tester,
      session,
      width: 360,
      scale: 1.15,
      brightness: Brightness.light,
    );
    await tester.tap(find.text('创建播放组'));
    await tester.pumpAndSettle();
    expect(session.actions, ['stop-preview', 'create']);
    await tester.tap(find.text('选择资源'));
    expect(session.actions.last, 'library');
    await tester.ensureVisible(find.text('解散播放组'));
    await tester.tap(find.text('解散播放组'));
    await tester.pumpAndSettle();
    expect(session.actions.last, 'leave');
    expect(find.text('创建播放组'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual address remains reachable and stops preview before join',
    (tester) async {
      final session = _MobileSession();
      await _showDevices(
        tester,
        session,
        width: 320,
        scale: 1.4,
        brightness: Brightness.dark,
      );
      await tester.ensureVisible(find.text('输入地址加入'));
      await tester.tap(find.text('输入地址加入'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '192.168.1.103:20888');
      await tester.tap(find.text('申请加入'));
      await tester.pumpAndSettle();
      // The existing dialog defers controller disposal until its exit finishes.
      await tester.pump(const Duration(seconds: 1));
      expect(session.actions, ['stop-preview', 'join:192.168.1.103:20888']);
      expect(tester.takeException(), isNull);
    },
  );
}
