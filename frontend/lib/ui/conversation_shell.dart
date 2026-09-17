import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_controller.dart';
import '../models/room_models.dart';
import '../models/speech_recognition_models.dart';
import '../services/room_session_controller.dart';

const _background = Color(0xFF07111F);
const _surface = Color(0xFF102235);
const _surfaceRaised = Color(0xFF162B3D);
const _cyan = Color(0xFF4EDDEA);
const _mint = Color(0xFF70E2B3);
const _yellow = Color(0xFFFFC857);
const _red = Color(0xFFFF718A);
const _muted = Color(0xFF91A6B8);

class ConversationShell extends StatefulWidget {
  const ConversationShell({
    super.key,
    required this.room,
    required this.appController,
    required this.signerView,
  });

  final RoomSessionController room;
  final AppController appController;
  final Widget signerView;

  @override
  State<ConversationShell> createState() => _ConversationShellState();
}

class _ConversationShellState extends State<ConversationShell> {
  int _signerTab = 0;

  @override
  Widget build(BuildContext context) {
    if (!widget.room.hasRoom) {
      return _RoomLobby(room: widget.room);
    }
    final content = widget.room.isSigner
        ? IndexedStack(
            index: _signerTab,
            children: <Widget>[
              widget.signerView,
              _ChatView(room: widget.room, appController: widget.appController),
            ],
          )
        : _ChatView(room: widget.room, appController: widget.appController);
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        titleSpacing: 18,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'SignBridge',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              'Room ${widget.room.credentials!.code} · ${_connectionLabel(widget.room.status)}',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ],
        ),
        actions: <Widget>[
          if (widget.room.isSigner)
            IconButton(
              tooltip: 'Invite the hearing participant',
              onPressed: () => _showInvitation(context),
              icon: const Icon(Icons.qr_code_2),
            ),
          IconButton(
            tooltip: 'End conversation',
            onPressed: () => _confirmEnd(context),
            icon: const Icon(Icons.call_end, color: _red),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: content,
      bottomNavigationBar: widget.room.isSigner
          ? NavigationBar(
              selectedIndex: _signerTab,
              onDestinationSelected: (value) =>
                  setState(() => _signerTab = value),
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.sign_language_outlined),
                  selectedIcon: Icon(Icons.sign_language),
                  label: 'Sign',
                ),
                NavigationDestination(
                  icon: Icon(Icons.forum_outlined),
                  selectedIcon: Icon(Icons.forum),
                  label: 'Conversation',
                ),
              ],
            )
          : null,
    );
  }

  Future<void> _showInvitation(BuildContext context) async {
    final uri = widget.room.invitationUri(Uri.base);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Invite the other person'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: uri.toString(), size: 210),
              ),
              const SizedBox(height: 14),
              SelectableText(
                widget.room.credentials!.code,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Scan the QR code or enter this eight-character code. The invitation contains no participant credential.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri.toString()));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy link'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEnd(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End this conversation?'),
        content: const Text(
          'The room closes for both people and its conversation state is erased.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep talking'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: _red),
            child: const Text('End conversation'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.room.end();
  }
}

class _RoomLobby extends StatefulWidget {
  const _RoomLobby({required this.room});
  final RoomSessionController room;

  @override
  State<_RoomLobby> createState() => _RoomLobbyState();
}

class _RoomLobbyState extends State<_RoomLobby> {
  final _name = TextEditingController();
  late final TextEditingController _code;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(
      text: (Uri.base.queryParameters['room'] ?? '').toUpperCase(),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 36),
                const Icon(Icons.sign_language, color: _cyan, size: 48),
                const SizedBox(height: 18),
                const Text(
                  'A conversation.\nTwo ways to connect.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 38,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.5,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Sign, speak, or type in one private two-person room.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, fontSize: 16),
                ),
                const SizedBox(height: 32),
                _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: _name,
                        maxLength: 40,
                        decoration: const InputDecoration(
                          labelText: 'Your name',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const ValueKey<String>('create-signing-room'),
                        onPressed: _busy ? null : () => _enter(join: false),
                        icon: const Icon(Icons.sign_language),
                        label: const Text('Start as the signer'),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Row(
                          children: <Widget>[
                            Expanded(child: Divider()),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'OR JOIN A SIGNER',
                                style: TextStyle(color: _muted),
                              ),
                            ),
                            Expanded(child: Divider()),
                          ],
                        ),
                      ),
                      TextField(
                        controller: _code,
                        maxLength: 8,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Eight-character room code',
                          prefixIcon: Icon(Icons.dialpad),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey<String>('join-hearing-room'),
                        onPressed: _busy ? null : () => _enter(join: true),
                        icon: const Icon(Icons.hearing),
                        label: const Text('Join as the hearing participant'),
                      ),
                      if (widget.room.error != null) ...<Widget>[
                        const SizedBox(height: 14),
                        Text(
                          widget.room.error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: _yellow),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(
                        widget.room.config.usesSameOriginGateway
                            ? 'Room gateway: ${widget.room.config.displayOrigin}'
                            : 'Backend: ${widget.room.config.displayOrigin}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _enter({required bool join}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (join) {
        await widget.room.join(_name.text, _code.text);
      } else {
        await widget.room.create(_name.text);
      }
    } on Object {
      // The controller exposes a safe, user-facing error.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ChatView extends StatefulWidget {
  const _ChatView({required this.room, required this.appController});

  final RoomSessionController room;
  final AppController appController;

  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  final _draft = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final partner = room.partner;
    final activity = partner == null ? null : room.activityFor(partner.id);
    return SafeArea(
      top: false,
      child: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: _surface,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Wrap(
              spacing: 10,
              runSpacing: 5,
              alignment: WrapAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  partner == null
                      ? 'Waiting for the other person…'
                      : '${partner.alias} · ${partner.online ? 'online' : 'reconnecting'}',
                  style: const TextStyle(color: _muted),
                ),
                if (activity != null && activity != 'idle')
                  Text(
                    '${partner?.alias ?? 'Partner'} is $activity…',
                    style: const TextStyle(color: _cyan),
                  ),
              ],
            ),
          ),
          Expanded(
            child: room.messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.sync_alt, color: _cyan, size: 45),
                          SizedBox(height: 14),
                          Text(
                            'Understanding starts here.',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 7),
                          Text(
                            'Signed, spoken, and typed messages appear on both screens.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _muted),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(18),
                    itemCount: room.messages.length,
                    itemBuilder: (context, index) => _MessageBubble(
                      message: room.messages[index],
                      mine:
                          room.messages[index].senderId ==
                          room.credentials?.participantId,
                      onSpeak: (text) =>
                          widget.appController.textToSpeech.speak(text),
                    ),
                  ),
          ),
          if (room.hasPendingRetry)
            MaterialBanner(
              content: const Text('A message is waiting for an exact retry.'),
              actions: <Widget>[
                TextButton(
                  onPressed: room.submissionInFlight ? null : room.retryPending,
                  child: const Text('Retry'),
                ),
              ],
            ),
          _SpeechComposer(room: room, appController: widget.appController),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('chat-message-draft'),
                    controller: _draft,
                    maxLength: 2000,
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (_) => room.sendActivity('typing'),
                    onSubmitted: (_) => _sendText(),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: 'Type a message…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey<String>('send-chat-message'),
                  tooltip: 'Send message',
                  onPressed: room.submissionInFlight ? null : _sendText,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendText() async {
    final text = _draft.text.trim();
    if (text.isEmpty) return;
    try {
      await widget.room.sendText(text);
      _draft.clear();
      widget.room.sendActivity('idle');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      });
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.room.error ?? 'The message could not be sent.',
            ),
          ),
        );
      }
    }
  }
}

class _SpeechComposer extends StatelessWidget {
  const _SpeechComposer({required this.room, required this.appController});

  final RoomSessionController room;
  final AppController appController;

  @override
  Widget build(BuildContext context) {
    final speech = appController.speechToText;
    final transcript = speech.transcript.trim();
    final listening =
        speech.isListening ||
        speech.status == SpeechServiceStatus.starting ||
        speech.status == SpeechServiceStatus.initializing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 5),
      child: _Panel(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  listening ? Icons.graphic_eq : Icons.mic_none,
                  color: listening ? _cyan : _mint,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    transcript.isEmpty
                        ? 'Speak, review the caption, then send it.'
                        : transcript,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: transcript.isEmpty ? _muted : Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const ValueKey<String>('toggle-speech-input'),
                  onPressed: () async {
                    if (listening) {
                      await speech.stopListening();
                      room.sendActivity('idle');
                    } else {
                      room.sendActivity('listening');
                      await speech.startListening();
                    }
                  },
                  icon: Icon(listening ? Icons.stop : Icons.mic),
                  label: Text(listening ? 'Stop' : 'Speak'),
                ),
                FilledButton.icon(
                  key: const ValueKey<String>('send-speech-message'),
                  onPressed: transcript.isEmpty || room.submissionInFlight
                      ? null
                      : () async {
                          if (listening) await speech.stopListening();
                          await room.sendText(transcript, source: 'speech');
                          speech.clearTranscript();
                          room.sendActivity('idle');
                        },
                  icon: const Icon(Icons.send),
                  label: const Text('Send spoken text'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.onSpeak,
  });

  final RoomMessage message;
  final bool mine;
  final ValueChanged<String> onSpeak;

  @override
  Widget build(BuildContext context) {
    final content = switch (message.status) {
      'processing' => 'Translating signed words…',
      'repair' =>
        message.repair?.prompt ?? 'Please repeat or type this message.',
      _ => message.text ?? '',
    };
    final color = message.status == 'repair'
        ? _yellow.withValues(alpha: .16)
        : mine
        ? _cyan.withValues(alpha: .17)
        : _surfaceRaised;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${mine ? 'You' : 'Partner'} · ${_sourceLabel(message.source)}',
              style: const TextStyle(color: _muted, fontSize: 10),
            ),
            const SizedBox(height: 4),
            Text(content, style: const TextStyle(fontSize: 16, height: 1.3)),
            if (message.status == 'repair') ...<Widget>[
              const SizedBox(height: 5),
              Text(
                message.repair?.reasonCode ?? 'clarification_needed',
                style: const TextStyle(color: _yellow, fontSize: 10),
              ),
            ],
            if (message.status == 'accepted' && content.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Read aloud',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onSpeak(message.ttsText ?? content),
                  icon: const Icon(Icons.volume_up_outlined, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: <Color>[_surfaceRaised, _surface]),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white12),
    ),
    child: child,
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

String _sourceLabel(String source) => switch (source) {
  'sign' => 'signed',
  'speech' => 'spoken',
  _ => 'typed',
};
