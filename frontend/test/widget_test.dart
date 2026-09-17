import 'package:apptesting/app_controller.dart';
import 'package:apptesting/config/room_client_config.dart';
import 'package:apptesting/main.dart';
import 'package:apptesting/services/device_access_service.dart';
import 'package:apptesting/services/local_state_service.dart';
import 'package:apptesting/services/room_session_controller.dart';
import 'package:apptesting/services/sign_analysis_service.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:apptesting/ui/sign_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppController> _controller() async {
  final preferences = await SharedPreferences.getInstance();
  return AppController(
    LocalStateService(preferences),
    DemoTrackingService(),
    DeviceAccessService(),
  );
}

Widget _host(Widget child) =>
    MaterialApp(theme: signBridgeTheme(), home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('confidence colours follow the 40%/30% gate', () {
    expect(Sb.confidenceColor(.81), Sb.good);
    expect(Sb.confidenceColor(.40), Sb.good);
    expect(Sb.confidenceColor(.35), Sb.warn);
    expect(Sb.confidenceColor(.30), Sb.warn);
    expect(Sb.confidenceColor(.29), Sb.bad);
    expect(Sb.confidenceColor(.10), Sb.bad);
  });

  testWidgets('a dedicated reload button sits left of the overflow menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
    await tester.pumpWidget(_host(SignScreen(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Restart camera'), findsOneWidget);
    expect(find.byTooltip('More options'), findsOneWidget);
    expect(
      tester.getCenter(find.byTooltip('Restart camera')).dx,
      lessThan(tester.getCenter(find.byTooltip('More options')).dx),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('the lobby asks for a name and offers both ways in', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
    final room = RoomSessionController(
      config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
    );
    await tester.pumpWidget(SignBridgeApp(controller: controller, room: room));
    await tester.pumpAndSettle();

    expect(find.text('SignBridge'), findsOneWidget);
    expect(find.text('Name *'), findsOneWidget);
    expect(find.text('Room code (optional)'), findsOneWidget);
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

  testWidgets('the lobby refuses to join a room without a code', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
    final room = RoomSessionController(
      config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
    );
    await tester.pumpWidget(SignBridgeApp(controller: controller, room: room));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('lobby-name')),
      'Ada',
    );
    await tester.tap(find.byKey(const ValueKey<String>('join-hearing-room')));
    await tester.pumpAndSettle();

    expect(find.text('Enter the signer’s room code to join them.'),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    room.dispose();
    controller.dispose();
  });

  testWidgets('the sign screen shows the recognised signs over the camera', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
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
    await tester.pumpWidget(_host(SignScreen(controller: controller)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('translated-utterance-buffer')),
      findsOneWidget,
    );
    expect(find.text('Sign a word to begin'), findsOneWidget);
    // Only one box shows the accepted sentence; the candidates for the
    // current sign are clickable chips below it, ranked by confidence, with
    // "Sign:" and "Confidence:" sharing one line.
    expect(
      find.byKey(const ValueKey<String>('pending-translated-words-review')),
      findsNothing,
    );
    expect(find.text('HELLO 81%'), findsOneWidget);
    expect(find.text('PLEASE 12%'), findsOneWidget);
    expect(find.text('Confidence: 81%'), findsOneWidget);
    // The highest-confidence candidate gets the main accent; the rest get a
    // light grey — a step up from the white card, but not accented.
    expect(
      tester
          .widget<Material>(
            find
                .ancestor(
                  of: find.byKey(
                    const ValueKey<String>('sign-candidate-hello'),
                  ),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color,
      Sb.primary,
    );
    expect(
      tester
          .widget<Material>(
            find
                .ancestor(
                  of: find.byKey(
                    const ValueKey<String>('sign-candidate-please'),
                  ),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color,
      Sb.surfaceStrong,
    );
    // Without a room there is nowhere to send a sentence, and the screen says
    // exactly that instead of printing backend chatter.
    expect(find.text('Start a room before sending a sentence.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('tapping a sign candidate adds it to the sentence', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
    controller.latestAnalysis = const SignAnalysisResult(
      status: 'candidate',
      gestureLabel: 'please',
      caption: 'Possible sign: please (55%)',
      confidence: .55,
      glossTrace: <String>[],
      hypotheses: <Map<String, dynamic>>[
        <String, dynamic>{'word': 'please', 'confidence': .55},
      ],
      modelVersion: 'signchat_asl_signs_onnx',
    );
    await tester.pumpWidget(_host(SignScreen(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('Sign a word to begin'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('sign-candidate-please')),
    );
    await tester.pumpAndSettle();

    expect(find.text('PLEASE'), findsOneWidget);
    expect(controller.translatedWords, <String>['PLEASE']);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('accepting a word pulses the caption card green, then fades back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
    controller.latestAnalysis = const SignAnalysisResult(
      status: 'candidate',
      gestureLabel: 'please',
      caption: 'Possible sign: please (55%)',
      confidence: .55,
      glossTrace: <String>[],
      hypotheses: <Map<String, dynamic>>[
        <String, dynamic>{'word': 'please', 'confidence': .55},
      ],
      modelVersion: 'signchat_asl_signs_onnx',
    );
    await tester.pumpWidget(_host(SignScreen(controller: controller)));
    await tester.pumpAndSettle();

    Color? cardColor() => (tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(
                      const ValueKey<String>('translated-utterance-buffer'),
                    ),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration
            as BoxDecoration?)
        ?.color;

    final before = cardColor();
    await tester.tap(
      find.byKey(const ValueKey<String>('sign-candidate-please')),
    );
    await tester.pump();
    // No sound plays; the card itself briefly pulses instead.
    expect(cardColor(), isNot(equals(before)));

    // Past the pulse window, the card is back to its normal colour — no
    // lingering tint.
    await tester.pump(const Duration(milliseconds: 900));
    expect(cardColor(), equals(before));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'resetting clears both the sentence buffer and its candidate read-out',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = await _controller();
      controller.latestAnalysis = const SignAnalysisResult(
        status: 'confident',
        gestureLabel: 'hello',
        caption: 'hello',
        confidence: .81,
        glossTrace: <String>['hello'],
        hypotheses: <Map<String, dynamic>>[
          <String, dynamic>{'word': 'hello', 'confidence': .81},
        ],
        modelVersion: 'signchat_asl_signs_onnx',
      );
      await tester.pumpWidget(_host(SignScreen(controller: controller)));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('sign-candidate-hello')),
      );
      await tester.pumpAndSettle();
      expect(controller.translatedWords, <String>['HELLO']);
      expect(find.text('HELLO 81%'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('reset-translated-utterance')),
      );
      await tester.pumpAndSettle();

      expect(controller.translatedWords, isEmpty);
      expect(find.text('Sign a word to begin'), findsOneWidget);
      expect(find.text('HELLO 81%'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('recognition details keep the model read-out', (tester) async {
    const analysis = SignAnalysisResult(
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
    await tester.pumpWidget(_host(const RecognitionDetails(analysis: analysis)));
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
  });

  testWidgets('a personal sign can be recorded without any calibration step', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = await _controller();
    await tester.pumpWidget(_host(CustomSignScreen(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('What does this sign mean? *'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('record-custom-sign-sample')),
      findsOneWidget,
    );
    expect(find.text('My signs · 0'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
