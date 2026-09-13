import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'conversation_open_stub.dart'
    if (dart.library.js_interop) 'conversation_open_web.dart';

/// The two-device MVP is a browser companion, accessible without an app install.
class ConversationLaunchCard extends StatelessWidget {
  const ConversationLaunchCard({super.key});

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: const Icon(Icons.forum_outlined),
      title: const Text('Two-device conversation'),
      subtitle: const Text(
        'Share a room. Sign, speak, or type on your own screens.',
      ),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const _ConversationAddressDialog(),
      ),
    ),
  );
}

class _ConversationAddressDialog extends StatefulWidget {
  const _ConversationAddressDialog();

  @override
  State<_ConversationAddressDialog> createState() =>
      _ConversationAddressDialogState();
}

class _ConversationAddressDialogState
    extends State<_ConversationAddressDialog> {
  static const _configured = String.fromEnvironment('CONVERSATION_URL');
  final _input = TextEditingController(
    text: _configured.isNotEmpty
        ? _configured
        : 'http://localhost:8000/conversation',
  );
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(_input.text.trim());
    if (uri == null ||
        !<String>['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => _error = 'Enter a complete http:// or https:// address.');
      return;
    }
    if (!openConversation(uri)) {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link copied. Open it in your browser.')),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Open shared conversation'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text('Use the room service address reachable by both devices.'),
        const SizedBox(height: 16),
        TextField(
          controller: _input,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Conversation address',
            errorText: _error,
          ),
        ),
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _open,
        child: Text(
          canOpenConversation ? 'Open in browser' : 'Copy browser link',
        ),
      ),
    ],
  );
}
