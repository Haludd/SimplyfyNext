import 'package:apptesting/main.dart';
import 'package:apptesting/app_controller.dart';
import 'package:apptesting/config/room_client_config.dart';
import 'package:apptesting/services/device_access_service.dart';
import 'package:apptesting/services/local_state_service.dart';
import 'package:apptesting/services/sign_analysis_service.dart';
import 'package:apptesting/services/room_session_controller.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the two-way room lobby', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = AppController(
      LocalStateService(preferences),
      DemoTrackingService(),
      DeviceAccessService(),
    );
    final room = RoomSessionController(
      config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
    );
    await tester.pumpWidget(SignBridgeApp(controller: controller, room: room));

    await tester.pumpAndSettle();

    expect(find.text('A conversation.\nTwo ways to connect.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('create-signing-room')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('join-hearing-room')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    room.dispose();
    controller.dispose();
  });

  testWidgets('shows a completed ASL recognition in the live preview output', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'calibrated': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final controller = AppController(
      LocalStateService(preferences),
      DemoTrackingService(),
      DeviceAccessService(),
    );
    controller.latestAnalysis = const SignAnalysisResult(
      status: 'confident',
      gestureLabel: 'hello',
      caption: 'hello',
      confidence: .81,
      glossTrace: <String>['hello'],
      hypotheses: <Map<String, dynamic>>[
        <String, dynamic>{'word': 'hello', 'confidence': .81},
        <String, dynamic>{'word': 'please', 'confidence': .12},
      ],
      modelVersion: 'signchat_asl_signs_onnx',
    );
    controller.backendStatus =
        'Utterance accepted · waiting for the room result';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveTranslatorScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('local-asl-model-output')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('local-asl-recognized-word')),
      findsOneWidget,
    );
    expect(find.text('HELLO'), findsOneWidget);
    expect(find.text('hello 81%  ·  please 12%'), findsOneWidget);
    expect(
      find.text('Utterance accepted · waiting for the room result'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('translated-utterance-buffer')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'allows adding a personal sign without completing onboarding calibration',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final controller = AppController(
        LocalStateService(preferences),
        DemoTrackingService(),
        DeviceAccessService(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LiveTranslatorScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      final mySigns = find.text('My signs');
      await tester.ensureVisible(mySigns);
      await tester.tap(mySigns);
      await tester.pumpAndSettle();
      final addCustomSign = find.text('Add custom sign');
      await tester.ensureVisible(addCustomSign);
      await tester.tap(addCustomSign);
      await tester.pumpAndSettle();

      expect(find.text('Teach SignBridge a sign'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
