import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_controller.dart';
import '../services/room_session_controller.dart';
import 'gesture_shortcuts_sheet.dart';
import 'speech_captions_sheet.dart';
import 'theme.dart';

/// Tabs the shell can show. The signer sees all three; the hearing participant
/// only ever has the conversation.
enum ShellTab { sign, chat, customSign }

/// The single overflow menu shared by every screen.
///
/// Everything that used to sit on the screen as a permanent control — camera
/// actions, playback, view mode, shortcuts, the invitation — lives here, so the
/// screens themselves only carry what a person reads.
class ShellMenu extends StatelessWidget {
  const ShellMenu({
    super.key,
    required this.appController,
    required this.room,
    required this.onSelectTab,
    this.cameraActions = false,
    this.signActions = false,
    this.onCamera = false,
  });

  final AppController appController;
  final RoomSessionController? room;
  final ValueChanged<ShellTab> onSelectTab;

  /// Restart / flip / turn off the camera, and the tracking overlay toggle.
  final bool cameraActions;

  /// Pause, read aloud, gesture shortcuts: only meaningful while translating.
  final bool signActions;

  /// Render the button as a light chip on top of the video feed.
  final bool onCamera;

  @override
  Widget build(BuildContext context) {
    final session = room;
    final isSigner = session?.isSigner ?? false;
    final cameraReady = appController.devices.cameraReady;
    return PopupMenuButton<String>(
      tooltip: 'More options',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      onSelected: (value) => _run(context, value),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        if (session != null && isSigner)
          _item('tab-sign', Icons.sign_language_outlined, 'Sign'),
        if (session != null)
          _item('tab-chat', Icons.chat_bubble_outline, 'Chat'),
        if (session != null && isSigner)
          _item('tab-custom', Icons.gesture_outlined, 'My sign'),
        if (session != null) const PopupMenuDivider(),
        if (cameraActions)
          _item(
            'camera-toggle',
            cameraReady ? Icons.videocam_off_outlined : Icons.videocam_outlined,
            cameraReady ? 'Turn camera off' : 'Turn camera on',
          ),
        if (cameraActions)
          _item('camera-restart', Icons.refresh, 'Restart camera'),
        if (cameraActions)
          _item('camera-flip', Icons.cameraswitch_outlined, 'Flip camera'),
        if (cameraActions)
          _item(
            'overlay',
            Icons.auto_awesome_motion_outlined,
            'Tracking overlay',
            checked: appController.viewMode == ViewMode.wireframe,
          ),
        if (cameraActions) const PopupMenuDivider(),
        _item(
          'audio',
          Icons.volume_up_outlined,
          'Speak messages aloud',
          checked: appController.audioEnabled,
        ),
        if (signActions)
          _item(
            'pause',
            Icons.pause_circle_outline,
            'Pause translation',
            checked: appController.isPaused,
          ),
        if (signActions)
          _item('speech', Icons.mic_none_outlined, 'Speech captions'),
        if (signActions)
          _item('shortcuts', Icons.bolt_outlined, 'Gesture shortcuts'),
        if (session != null) ...<PopupMenuEntry<String>>[
          const PopupMenuDivider(),
          if (isSigner) _item('invite', Icons.qr_code_2, 'Invite'),
          _item('end', Icons.logout, 'End conversation', danger: true),
        ],
      ],
      child: onCamera
          ? const _MenuChip()
          : const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.more_horiz, color: Sb.text),
            ),
    );
  }

  static PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String label, {
    bool checked = false,
    bool danger = false,
  }) => PopupMenuItem<String>(
    value: value,
    height: 46,
    child: Row(
      children: <Widget>[
        Icon(icon, size: 20, color: danger ? Sb.bad : Sb.textMuted),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              color: danger ? Sb.bad : Sb.text,
            ),
          ),
        ),
        if (checked) const Icon(Icons.check, size: 18, color: Sb.primaryStrong),
      ],
    ),
  );

  Future<void> _run(BuildContext context, String value) async {
    if (value == 'tab-sign') {
      onSelectTab(ShellTab.sign);
      return;
    }
    if (value == 'tab-chat') {
      onSelectTab(ShellTab.chat);
      return;
    }
    if (value == 'tab-custom') {
      onSelectTab(ShellTab.customSign);
      return;
    }
    if (value == 'camera-toggle') {
      await appController.toggleCamera();
      return;
    }
    if (value == 'camera-restart') {
      await appController.restartCamera();
      return;
    }
    if (value == 'camera-flip') {
      await appController.switchCamera();
      return;
    }
    if (value == 'overlay') {
      appController.setViewMode(
        appController.viewMode == ViewMode.wireframe
            ? ViewMode.raw
            : ViewMode.wireframe,
      );
      return;
    }
    if (value == 'audio') {
      appController.toggleAudio();
      return;
    }
    if (value == 'pause') {
      appController.togglePause();
      return;
    }
    if (!context.mounted) return;
    if (value == 'speech') {
      await showSpeechCaptionsSheet(context, appController);
      return;
    }
    if (value == 'shortcuts') {
      await showGestureShortcutsSheet(context, appController);
      return;
    }
    if (value == 'invite') {
      await _showInvitation(context);
      return;
    }
    if (value == 'end') {
      await _confirmEnd(context);
    }
  }

  Future<void> _showInvitation(BuildContext context) async {
    final session = room;
    final credentials = session?.credentials;
    if (session == null || credentials == null) return;
    final uri = session.invitationUri(Uri.base);
    await showSbSheet<void>(
      context,
      builder: (sheetContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SheetTitle('Invite'),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: Sb.gutter),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(Sb.radius),
                border: Border.all(color: Sb.border),
              ),
              child: QrImageView(data: uri.toString(), size: 190),
            ),
            const SizedBox(height: 18),
            SelectableText(
              credentials.code,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Scan the code or share the eight characters. The invitation carries no credential.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Sb.textMuted, fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(Sb.gutter, 0, Sb.gutter, 20),
              child: FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: uri.toString()),
                  );
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
                icon: const Icon(Icons.link, size: 19),
                label: const Text('Copy invite link'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmEnd(BuildContext context) async {
    final session = room;
    if (session == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End this conversation?'),
        content: const Text(
          'The room closes for both people and its conversation is erased.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep talking'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Sb.bad),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.end();
  }
}

class _MenuChip extends StatelessWidget {
  const _MenuChip();

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: const BoxDecoration(
      color: Sb.overlayChip,
      shape: BoxShape.circle,
    ),
    child: const Icon(Icons.more_horiz, color: Sb.text, size: 22),
  );
}
