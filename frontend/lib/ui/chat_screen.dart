import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/room_models.dart';
import '../models/speech_recognition_models.dart';
import '../services/room_session_controller.dart';
import 'theme.dart';

/// The conversation, in the shape people already know from their phone:
/// bubbles, a rounded composer, and dictation on the left of it.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.room,
    required this.appController,
  });

  final RoomSessionController room;
  final AppController appController;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  bool _dictating = false;
  bool _draftFromSpeech = false;
  int _seenMessages = 0;

  @override
  void initState() {
    super.initState();
    widget.appController.speechToText.addListener(_onSpeechUpdate);
    _draft.addListener(_refreshSendButton);
  }

  @override
  void dispose() {
    widget.appController.speechToText.removeListener(_onSpeechUpdate);
    _draft.removeListener(_refreshSendButton);
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refreshSendButton() {
    if (mounted) setState(() {});
  }

  /// While the microphone is on, the transcript is written straight into the
  /// draft so the person edits and sends it like any other message.
  void _onSpeechUpdate() {
    if (!_dictating || !mounted) return;
    final speech = widget.appController.speechToText;
    final text = speech.transcript.trim();
    if (text.isNotEmpty && text != _draft.text) {
      _draftFromSpeech = true;
      _draft.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    if (!speech.isListening &&
        speech.status != SpeechServiceStatus.starting &&
        speech.status != SpeechServiceStatus.initializing) {
      setState(() => _dictating = false);
      widget.room.sendActivity('idle');
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final partner = room.partner;
    final activity = partner == null ? null : room.activityFor(partner.id);
    final showActivity = activity != null && activity != 'idle';
    final messages = room.messages;
    if (messages.length != _seenMessages) {
      _seenMessages = messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: messages.isEmpty
              ? _EmptyConversation(waitingForPartner: partner == null)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  itemCount: messages.length + (showActivity ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      return _TypingBubble(activity: activity!);
                    }
                    final message = messages[index];
                    return _MessageBubble(
                      message: message,
                      mine:
                          message.senderId == room.credentials?.participantId,
                      onSpeak: (text) =>
                          widget.appController.textToSpeech.speak(text),
                    );
                  },
                ),
        ),
        if (room.hasPendingRetry)
          _RetryBar(
            busy: room.submissionInFlight,
            onRetry: room.retryPending,
          ),
        _Composer(
          draft: _draft,
          dictating: _dictating,
          canSend: _draft.text.trim().isNotEmpty && !room.submissionInFlight,
          onChanged: (_) {
            _draftFromSpeech = false;
            room.sendActivity('typing');
          },
          onToggleDictation: _toggleDictation,
          onSend: _send,
        ),
      ],
    );
  }

  void _scrollToEnd() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _toggleDictation() async {
    final speech = widget.appController.speechToText;
    if (_dictating) {
      await speech.stopListening();
      if (!mounted) return;
      setState(() => _dictating = false);
      widget.room.sendActivity('idle');
      return;
    }
    speech.clearTranscript();
    setState(() => _dictating = true);
    widget.room.sendActivity('listening');
    await speech.startListening();
    if (!mounted) return;
    if (speech.status == SpeechServiceStatus.error ||
        speech.status == SpeechServiceStatus.unavailable) {
      setState(() => _dictating = false);
      widget.room.sendActivity('idle');
      _showError(
        speech.status == SpeechServiceStatus.unavailable
            ? 'Speech recognition is unavailable on this device.'
            : 'The microphone could not start.',
      );
    }
  }

  Future<void> _send() async {
    final text = _draft.text.trim();
    if (text.isEmpty) return;
    final speech = widget.appController.speechToText;
    if (_dictating) {
      await speech.stopListening();
      if (mounted) setState(() => _dictating = false);
    }
    try {
      await widget.room.sendText(
        text,
        source: _draftFromSpeech ? 'speech' : 'text',
      );
      if (!mounted) return;
      _draft.clear();
      _draftFromSpeech = false;
      speech.clearTranscript();
      widget.room.sendActivity('idle');
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    } on Object {
      _showError(widget.room.error ?? 'The message could not be sent.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.waitingForPartner});

  final bool waitingForPartner;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 44),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            waitingForPartner
                ? Icons.hourglass_empty_rounded
                : Icons.forum_outlined,
            size: 34,
            color: Sb.textFaint,
          ),
          const SizedBox(height: 16),
          Text(
            waitingForPartner
                ? 'Waiting for the other person'
                : 'Say something',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            waitingForPartner
                ? 'Share the room code from the menu to bring them in.'
                : 'Signed, spoken, and typed messages all land here.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Sb.textMuted,
              fontSize: 14,
              height: 1.45,
            ),
          ),
        ],
      ),
    ),
  );
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
    final processing = message.status == 'processing';
    final repair = message.status == 'repair';
    final content = switch (message.status) {
      'processing' => 'Translating…',
      'repair' =>
        message.repair?.prompt ?? 'Please repeat or type this message.',
      _ => message.text ?? '',
    };
    final background = repair
        ? Sb.warn.withValues(alpha: .16)
        : mine
        ? Sb.primary
        : Sb.surface;
    final foreground = mine && !repair ? Colors.white : Sb.text;
    final caption = _caption(message);
    // The hearing participant hears incoming messages automatically; this
    // repeats one on demand.
    final canSpeak =
        !mine && message.status == 'accepted' && content.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: <Widget>[
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * .78,
            ),
            child: GestureDetector(
              onLongPress: message.status == 'accepted' && content.isNotEmpty
                  ? () => onSpeak(message.ttsText ?? content)
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20),
                    topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(mine ? 20 : 6),
                    bottomRight: Radius.circular(mine ? 6 : 20),
                  ),
                ),
                child: Text(
                  content,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 16,
                    height: 1.35,
                    fontStyle: processing ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
            ),
          ),
          if (caption != null || canSpeak)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (canSpeak)
                    InkWell(
                      onTap: () => onSpeak(message.ttsText ?? content),
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(0, 2, 5, 2),
                        child: Icon(
                          Icons.volume_up_outlined,
                          size: 15,
                          color: Sb.textMuted,
                        ),
                      ),
                    ),
                  if (caption != null)
                    Text(
                      caption,
                      style: const TextStyle(
                        color: Sb.textFaint,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Only says something the bubble does not already show: how a message was
  /// produced, or why it needs repeating.
  static String? _caption(RoomMessage message) {
    if (message.status == 'repair') {
      return message.repair?.reasonCode ?? 'clarification needed';
    }
    return switch (message.source) {
      'sign' => 'signed',
      'speech' => 'spoken',
      _ => null,
    };
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.activity});

  final String activity;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: const BoxDecoration(
        color: Sb.surface,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(6),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Text(
        switch (activity) {
          'signing' => 'signing…',
          'listening' => 'listening…',
          _ => 'typing…',
        },
        style: const TextStyle(color: Sb.textMuted, fontSize: 14),
      ),
    ),
  );
}

class _RetryBar extends StatelessWidget {
  const _RetryBar({required this.busy, required this.onRetry});

  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Sb.warn.withValues(alpha: .14),
    padding: const EdgeInsets.fromLTRB(Sb.gutter, 8, 8, 8),
    child: Row(
      children: <Widget>[
        const Expanded(
          child: Text(
            'A message is waiting to be sent.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: busy ? null : onRetry,
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.draft,
    required this.dictating,
    required this.canSend,
    required this.onChanged,
    required this.onToggleDictation,
    required this.onSend,
  });

  final TextEditingController draft;
  final bool dictating;
  final bool canSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleDictation;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Sb.background,
      border: Border(top: BorderSide(color: Sb.border)),
    ),
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
    child: SafeArea(
      top: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('toggle-speech-input'),
            tooltip: dictating ? 'Stop dictation' : 'Dictate a message',
            onPressed: onToggleDictation,
            icon: Icon(
              dictating ? Icons.stop_circle : Icons.mic_none_rounded,
              color: dictating ? Sb.bad : Sb.textMuted,
              size: 26,
            ),
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              decoration: BoxDecoration(
                color: Sb.surface,
                borderRadius: BorderRadius.circular(22),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const ValueKey<String>('chat-message-draft'),
                controller: draft,
                maxLength: 2000,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                onChanged: onChanged,
                style: const TextStyle(fontSize: 16, height: 1.3),
                decoration: InputDecoration(
                  counterText: '',
                  filled: false,
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  hintText: dictating ? 'Listening…' : 'Message',
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _SendButton(
            key: const ValueKey<String>('send-chat-message'),
            enabled: canSend,
            onPressed: onSend,
          ),
        ],
      ),
    ),
  );
}

class _SendButton extends StatelessWidget {
  const _SendButton({super.key, required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Send',
    child: Material(
      color: enabled ? Sb.primary : Sb.surfaceStrong,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            Icons.arrow_upward_rounded,
            size: 22,
            color: enabled ? Colors.white : Sb.textFaint,
          ),
        ),
      ),
    ),
  );
}
