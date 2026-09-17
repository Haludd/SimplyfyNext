import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'theme.dart';

/// Maps a saved personal sign onto one of the three hands-free actions.
///
/// This used to be a permanent card on the translating screen; it is a setup
/// step, so it lives one tap away in the menu instead.
Future<void> showGestureShortcutsSheet(
  BuildContext context,
  AppController controller,
) async {
  await showSbSheet<void>(
    context,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _GestureShortcuts(controller: controller),
    ),
  );
}

class _GestureShortcuts extends StatelessWidget {
  const _GestureShortcuts({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[];
    final seen = <String>{};
    for (final sign in controller.customSigns) {
      if (!sign.hasEnoughSamples ||
          sign.language.toUpperCase() !=
              controller.selectedLanguage.trim().toUpperCase() ||
          !seen.add(sign.label.trim().toLowerCase())) {
        continue;
      }
      labels.add(sign.label);
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SheetTitle('Gesture shortcuts'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Sb.gutter, 0, Sb.gutter, 18),
            child: Text(
              labels.isEmpty
                  ? 'Record a personal sign under My sign first. Once a sign has five samples you can map it to an action here, and the mapping stays on this device.'
                  : 'Choose one saved personal sign per action. The mapping stays on this device.',
              style: const TextStyle(
                color: Sb.textMuted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
          if (labels.isNotEmpty) ...<Widget>[
            _ShortcutPicker(
              controller: controller,
              labels: labels,
              shortcut: PersonalSignShortcut.addPossibleWord,
              label: 'Add possible word',
              helper: 'Keeps the current low-confidence suggestion.',
            ),
            _ShortcutPicker(
              controller: controller,
              labels: labels,
              shortcut: PersonalSignShortcut.deleteLastWord,
              label: 'Delete latest word',
              helper: 'Removes the newest word in the sentence.',
            ),
            _ShortcutPicker(
              controller: controller,
              labels: labels,
              shortcut: PersonalSignShortcut.sendSentence,
              label: 'Send sentence',
              helper: 'Sends the words already in the sentence.',
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ShortcutPicker extends StatelessWidget {
  const _ShortcutPicker({
    required this.controller,
    required this.labels,
    required this.shortcut,
    required this.label,
    required this.helper,
  });

  final AppController controller;
  final List<String> labels;
  final PersonalSignShortcut shortcut;
  final String label;
  final String helper;

  @override
  Widget build(BuildContext context) {
    final selected = controller.shortcutLabelFor(shortcut);
    final selectedValue =
        labels.any((value) => value.toLowerCase() == selected?.toLowerCase())
        ? selected!
        : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sb.gutter, 0, Sb.gutter, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            helper,
            style: const TextStyle(color: Sb.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(
              'gesture-shortcut-${shortcut.storageKey}-$selectedValue',
            ),
            initialValue: selectedValue,
            isExpanded: true,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: '',
                child: Text('Off · use the on-screen button'),
              ),
              ...labels.map(
                (value) =>
                    DropdownMenuItem<String>(value: value, child: Text(value)),
              ),
            ],
            onChanged: (value) => unawaited(
              controller.setPersonalSignShortcut(
                shortcut,
                value == null || value.isEmpty ? null : value,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
