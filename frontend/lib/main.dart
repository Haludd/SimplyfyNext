import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_controller.dart';
import 'config/room_client_config.dart';
import 'services/device_access_service.dart';
import 'services/local_state_service.dart';
import 'services/room_session_controller.dart';
import 'services/state_normalised_tracking_service.dart';
import 'services/tracking_service.dart';
import 'services/web_tracking_service.dart';
import 'ui/conversation_shell.dart';
import 'ui/theme.dart';

export 'ui/chat_screen.dart' show ChatScreen;
export 'ui/conversation_shell.dart' show ConversationShell;
export 'ui/custom_sign_screen.dart' show CustomSignScreen;
export 'ui/lobby_screen.dart' show LobbyScreen;
export 'ui/shell_menu.dart' show ShellMenu, ShellTab;
export 'ui/sign_screen.dart' show SignScreen;
export 'ui/theme.dart' show Sb, signBridgeTheme;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final TrackingService mediaPipeCapture = kIsWeb
      ? WebTrackingService()
      : DemoTrackingService();
  // Keep the UI on top of the complete perception pipeline:
  // MediaPipe capture -> stable tracking state -> body-relative normalisation.
  final TrackingService mediaPipeTracking = StateNormalisedTrackingService(
    mediaPipeCapture,
  );
  final room = RoomSessionController(
    config: RoomClientConfig.fromEnvironment(),
  );
  final controller = AppController(
    LocalStateService(preferences),
    mediaPipeTracking,
    DeviceAccessService(),
    utteranceSubmission: room,
  );
  room.onIncomingSignedText = (text) async {
    if (room.isHearing && controller.audioEnabled) {
      await controller.textToSpeech.speak(text);
    }
  };
  unawaited(room.restore());
  runApp(SignBridgeApp(controller: controller, room: room));
}

class SignBridgeApp extends StatelessWidget {
  const SignBridgeApp({
    super.key,
    required this.controller,
    required this.room,
  });

  final AppController controller;
  final RoomSessionController room;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'SignBridge',
    theme: signBridgeTheme(),
    home: AppShell(controller: controller, room: room),
  );
}

/// Rebuilds the shell whenever the controller, the devices, or the room change,
/// so every screen below reads one consistent snapshot.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.controller, required this.room});

  final AppController controller;
  final RoomSessionController room;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[
      controller,
      controller.devices,
      room,
    ]),
    builder: (context, _) =>
        ConversationShell(room: room, appController: controller),
  );
}
