import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/room_models.dart';
import '../services/room_session_controller.dart';
import 'chat_screen.dart';
import 'custom_sign_screen.dart';
import 'lobby_screen.dart';
import 'shell_menu.dart';
import 'sign_screen.dart';
import 'theme.dart';

export 'shell_menu.dart' show ShellTab;

/// Chooses between the lobby and the conversation, and owns the three tabs.
class ConversationShell extends StatefulWidget {
  const ConversationShell({
    super.key,
    required this.room,
    required this.appController,
  });

  final RoomSessionController room;
  final AppController appController;

  @override
  State<ConversationShell> createState() => _ConversationShellState();
}

class _ConversationShellState extends State<ConversationShell> {
  ShellTab _tab = ShellTab.sign;

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    if (!room.hasRoom) return LobbyScreen(room: room);

    final isSigner = room.isSigner;
    // Only a signer has a camera pipeline; the hearing participant's whole
    // screen is the conversation.
    final tab = isSigner ? _tab : ShellTab.chat;
    final onCameraTab = tab != ShellTab.chat;

    return Scaffold(
      backgroundColor: onCameraTab ? Sb.cameraVoid : Sb.background,
      // Both the chat composer and the sign-meaning field must stay above the
      // keyboard; the translating screen has no text input to lift.
      resizeToAvoidBottomInset: tab != ShellTab.sign,
      appBar: onCameraTab ? null : _chatAppBar(room),
      body: isSigner
          ? IndexedStack(
              index: tab.index,
              sizing: StackFit.expand,
              children: <Widget>[
                SignScreen(
                  controller: widget.appController,
                  room: room,
                  onSelectTab: _select,
                ),
                ChatScreen(room: room, appController: widget.appController),
                CustomSignScreen(
                  controller: widget.appController,
                  room: room,
                  onSelectTab: _select,
                ),
              ],
            )
          : ChatScreen(room: room, appController: widget.appController),
      bottomNavigationBar: isSigner
          ? _TabBar(current: tab, onSelect: _select)
          : null,
    );
  }

  PreferredSizeWidget _chatAppBar(RoomSessionController room) {
    final partner = room.partner;
    final connected = room.status == RoomConnectionStatus.connected;
    return AppBar(
      titleSpacing: Sb.gutter,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            partner?.alias ?? 'Waiting for the other person',
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            connected && partner != null
                ? (partner.online ? 'online' : 'reconnecting')
                : '${room.credentials!.code} · ${_connectionLabel(room.status)}',
            style: const TextStyle(
              color: Sb.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        ShellMenu(
          appController: widget.appController,
          room: room,
          onSelectTab: _select,
          cameraActions: room.isSigner,
        ),
        const SizedBox(width: 4),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1),
      ),
    );
  }

  void _select(ShellTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});

  final ShellTab current;
  final ValueChanged<ShellTab> onSelect;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Sb.background,
      border: Border(top: BorderSide(color: Sb.border)),
    ),
    child: NavigationBar(
      selectedIndex: current.index,
      onDestinationSelected: (index) => onSelect(ShellTab.values[index]),
      destinations: const <NavigationDestination>[
        NavigationDestination(
          icon: Icon(Icons.sign_language_outlined),
          selectedIcon: Icon(Icons.sign_language),
          label: 'Sign',
        ),
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Chat',
        ),
        NavigationDestination(
          icon: Icon(Icons.gesture_outlined),
          selectedIcon: Icon(Icons.gesture),
          label: 'Custom Sign',
        ),
      ],
    ),
  );
}

String _connectionLabel(RoomConnectionStatus status) => switch (status) {
  RoomConnectionStatus.connected => 'connected',
  RoomConnectionStatus.connecting => 'connecting',
  RoomConnectionStatus.reconnecting => 'reconnecting',
  RoomConnectionStatus.ended => 'ended',
  RoomConnectionStatus.error => 'connection error',
  _ => 'starting',
};
