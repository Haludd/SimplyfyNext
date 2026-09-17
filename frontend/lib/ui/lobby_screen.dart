import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/room_session_controller.dart';
import 'theme.dart';

/// Forces the room code to the uppercase alphabet the backend issues.
class _RoomCodeFormatter extends TextInputFormatter {
  const _RoomCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    return TextEditingValue(
      text: upper,
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

/// The first screen: a name, an optional room code, and the two ways in.
class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key, required this.room});

  final RoomSessionController room;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  late final TextEditingController _code;
  bool _busy = false;
  String? _validation;

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
    _nameFocus.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _validation ?? widget.room.error;
    return Scaffold(
      backgroundColor: Sb.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Sb.gutter,
              vertical: 32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Text(
                    'SignBridge',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.4,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextField(
                    key: const ValueKey<String>('lobby-name'),
                    controller: _name,
                    focusNode: _nameFocus,
                    maxLength: 40,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => _clearValidation(),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: 'Name *',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey<String>('lobby-room-code'),
                    controller: _code,
                    maxLength: 8,
                    textInputAction: TextInputAction.done,
                    inputFormatters: const <TextInputFormatter>[
                      _RoomCodeFormatter(),
                    ],
                    onChanged: (_) => _clearValidation(),
                    onSubmitted: (_) => _enter(asSigner: false),
                    decoration: const InputDecoration(
                      counterText: '',
                      hintText: 'Room code (optional)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'A room code is only needed to join a signer.',
                      style: TextStyle(color: Sb.textFaint, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey<String>('create-signing-room'),
                    onPressed: _busy ? null : () => _enter(asSigner: true),
                    child: const Text('Join as a signer'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey<String>('join-hearing-room'),
                    onPressed: _busy ? null : () => _enter(asSigner: false),
                    child: const Text('Join as a hearing person'),
                  ),
                  if (_busy) ...<Widget>[
                    const SizedBox(height: 20),
                    const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ],
                  if (error != null) ...<Widget>[
                    const SizedBox(height: 18),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Sb.bad,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    if (_validation == null) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        widget.room.config.displayOrigin,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Sb.textFaint,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _clearValidation() {
    if (_validation != null) setState(() => _validation = null);
  }

  Future<void> _enter({required bool asSigner}) async {
    if (_busy) return;
    final name = _name.text.trim();
    final code = _code.text.trim();
    if (name.isEmpty) {
      setState(() => _validation = 'Enter your name to continue.');
      _nameFocus.requestFocus();
      return;
    }
    if (!asSigner && code.isEmpty) {
      setState(
        () => _validation = 'Enter the signer’s room code to join them.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _validation = null;
    });
    try {
      // A signer always opens a new room; the code field is for joining one.
      if (asSigner) {
        await widget.room.create(name);
      } else {
        await widget.room.join(name, code);
      }
    } on Object {
      // The controller exposes a safe, user-facing error.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
