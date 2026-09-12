import 'package:apptesting/main.dart';
import 'package:apptesting/app_controller.dart';
import 'package:apptesting/services/device_access_service.dart';
import 'package:apptesting/services/local_state_service.dart';
import 'package:apptesting/services/sign_analysis_service.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the single live page with an open-camera action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final controller = AppController(
      LocalStateService(preferences),
      DemoTrackingService(),
      DeviceAccessService(),
    );
    await tester.pumpWidget(SignBridgeApp(controller: controller));

    await tester.pumpAndSettle();

    expect(find.text('Live translator'), findsOneWidget);
    expect(find.text('Open camera'), findsOneWidget);
    expect(find.text('My signs'), findsNothing);
    expect(find.text('Settings'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
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
      modelVersion: 'google_asl_25_v20250723_042752',
    );
    controller.backendStatus = 'Word sent to backend · accepted';

    await tester.pumpWidget(SignBridgeApp(controller: controller));
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
    expect(find.text('Word sent to backend · accepted'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
