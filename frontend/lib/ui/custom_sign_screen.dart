import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../services/room_session_controller.dart';
import '../services/sign_analysis_service.dart';
import 'camera_stage.dart';
import 'shell_menu.dart';
import 'theme.dart';

const int _requiredSamples = 5;
const String _readyMessage = 'Ready to record';

/// Teaches SignBridge a personal sign.
///
/// It is deliberately the same screen as [SignScreen] with one extra field:
/// the camera fills the view, and the only additions are the meaning of the
/// sign and the record button.
class CustomSignScreen extends StatefulWidget {
  const CustomSignScreen({
    super.key,
    required this.controller,
    this.room,
    this.onSelectTab,
  });

  final AppController controller;
  final RoomSessionController? room;
  final ValueChanged<ShellTab>? onSelectTab;

  @override
  State<CustomSignScreen> createState() => _CustomSignScreenState();
}

class _CustomSignScreenState extends State<CustomSignScreen> {
  final TextEditingController _label = TextEditingController();
  final List<List<List<double>>> _samples = <List<List<double>>>[];
  bool _recording = false;
  String? _error;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The reset action appears as soon as there is something to reset.
    _label.addListener(_onLabelChanged);
  }

  void _onLabelChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _label.removeListener(_onLabelChanged);
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraReady = controller.devices.cameraReady;
    return ColoredBox(
      color: Sb.cameraVoid,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CameraStage(controller: controller, showCalibrationGuide: true),
          if (!cameraReady) _cameraOff(),
          if (_recording) const _RecordingBadge(),
          SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned(
                  top: 12,
                  left: Sb.gutter,
                  child: _LibraryButton(
                    count: controller.customSigns.length,
                    onTap: () => _openLibrary(context),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: Sb.gutter - 8,
                  child: ShellMenu(
                    appController: controller,
                    room: widget.room,
                    onSelectTab: widget.onSelectTab ?? (_) {},
                    cameraActions: true,
                    onCamera: true,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: FractionallySizedBox(
                    widthFactor: .9,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _RecorderPanel(
                        label: _label,
                        samples: _samples.length,
                        recording: _recording,
                        error: _error,
                        status: _readiness(),
                        ready: _readiness() == _readyMessage,
                        onRecord: _record,
                        onReset: _samples.isEmpty && _label.text.isEmpty
                            ? null
                            : _reset,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cameraOff() => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      decoration: BoxDecoration(
        color: Sb.overlay,
        borderRadius: BorderRadius.circular(Sb.radiusLarge),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Camera is off',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Recording a personal sign needs the camera.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Sb.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => controller.requestCamera(),
            child: const Text('Turn on camera'),
          ),
        ],
      ),
    ),
  );

  /// One short line replaces the old four-item checklist; the detail it used to
  /// spell out is what the line already names as missing.
  String _readiness() {
    if (!controller.devices.cameraReady) return 'Turn on the camera';
    final frame = controller.latestFrame;
    if (frame?.shouldersVisible != true) return 'Keep both shoulders in view';
    if (frame?.handsVisible != true) return 'Show at least one hand';
    if ((frame?.trackingConfidence ?? 0) < .70) {
      return 'Improving tracking…';
    }
    return _readyMessage;
  }

  void _reset() {
    setState(() {
      _label.clear();
      _samples.clear();
      _error = null;
    });
  }

  Future<void> _record() async {
    if (_recording) return;
    if (_samples.length == _requiredSamples) {
      final name = _label.text.trim();
      if (name.isEmpty) {
        setState(() => _error = 'Name this sign before saving it.');
        return;
      }
      await controller.saveCustomSign(name, _samples);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“$name” saved to your signs.')),
      );
      _reset();
      return;
    }
    if (!controller.devices.cameraReady) {
      setState(() => _error = 'Turn on the camera before recording.');
      return;
    }
    setState(() {
      _recording = true;
      _error = null;
    });
    final startedAt = DateTime.now();
    controller.setPersonalSignRecording(true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      final sample = controller.capturePersonalSignSequence(startedAt);
      if (!mounted) return;
      if (sample == null) {
        setState(() {
          _recording = false;
          _error =
              'That take was not clear enough. Keep a hand and both shoulders in frame, then try again.';
        });
        return;
      }
      setState(() {
        _samples.add(sample);
        _recording = false;
      });
    } finally {
      controller.setPersonalSignRecording(false);
    }
  }

  Future<void> _openLibrary(BuildContext context) async {
    await showSbSheet<void>(
      context,
      builder: (sheetContext) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _SignLibrary(controller: controller),
      ),
    );
  }
}

class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Sb.bad,
          borderRadius: BorderRadius.circular(999),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
            SizedBox(width: 7),
            Text(
              'Perform the sign now',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LibraryButton extends StatelessWidget {
  const _LibraryButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Sb.overlayChip,
    borderRadius: BorderRadius.circular(999),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.collections_bookmark_outlined, size: 17),
            const SizedBox(width: 7),
            Text(
              'My signs · $count',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RecorderPanel extends StatelessWidget {
  const _RecorderPanel({
    required this.label,
    required this.samples,
    required this.recording,
    required this.error,
    required this.status,
    required this.ready,
    required this.onRecord,
    required this.onReset,
  });

  final TextEditingController label;
  final int samples;
  final bool recording;
  final String? error;
  final String status;
  final bool ready;
  final VoidCallback onRecord;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final complete = samples == _requiredSamples;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Sb.overlay,
        borderRadius: BorderRadius.circular(Sb.radiusLarge),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('custom-sign-label'),
            controller: label,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              counterText: '',
              hintText: 'What does this sign mean? *',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: ready ? Sb.good : Sb.warn,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error ?? status,
                  maxLines: 2,
                  style: TextStyle(
                    color: error == null ? Sb.textMuted : Sb.bad,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
              Text(
                '$samples/$_requiredSamples',
                style: const TextStyle(
                  color: Sb.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: List<Widget>.generate(
              _requiredSamples,
              (index) => Expanded(
                child: Container(
                  height: 4,
                  margin: EdgeInsets.only(
                    right: index == _requiredSamples - 1 ? 0 : 5,
                  ),
                  decoration: BoxDecoration(
                    color: index < samples ? Sb.primary : Sb.surfaceStrong,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              if (onReset != null) ...<Widget>[
                CameraIconButton(
                  icon: Icons.add,
                  tooltip: 'Start a new sign',
                  onPressed: onReset,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey<String>('record-custom-sign-sample'),
                  onPressed: recording ? null : onRecord,
                  icon: Icon(
                    complete
                        ? Icons.check_rounded
                        : Icons.fiber_manual_record_rounded,
                    size: 20,
                  ),
                  label: Text(
                    recording
                        ? 'Recording…'
                        : complete
                        ? 'Save sign'
                        : 'Record ${samples + 1} of $_requiredSamples',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Saved personal signs, their backup, and the reference vocabulary.
class _SignLibrary extends StatelessWidget {
  const _SignLibrary({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final signs = controller.customSigns;
    final reference = SignLexicon.entriesFor(controller.selectedLanguage);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SheetTitle(
            'My signs',
            trailing: IconButton(
              tooltip: 'Back up or restore',
              onPressed: () => _showBackupDialog(context),
              icon: const Icon(Icons.save_alt_outlined, color: Sb.textMuted),
            ),
          ),
          if (signs.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(Sb.gutter, 0, Sb.gutter, 8),
              child: Text(
                'Nothing saved yet. Record five clear takes of one sign to add it.',
                style: TextStyle(
                  color: Sb.textMuted,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
            )
          else
            ...signs.map(
              (sign) => ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Sb.gutter,
                ),
                title: Text(
                  sign.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  sign.hasEnoughSamples
                      ? '${sign.language} · ${sign.sampleCount} recordings'
                      : '${sign.language} · ${sign.sampleCount} recordings · needs more',
                  style: const TextStyle(color: Sb.textMuted, fontSize: 12),
                ),
                trailing: IconButton(
                  tooltip: 'Delete ${sign.label}',
                  onPressed: () => controller.deleteCustomSign(sign),
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Sb.textMuted,
                    size: 20,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 10),
          const Divider(indent: Sb.gutter, endIndent: Sb.gutter),
          const SizedBox(height: 14),
          SheetTitle(
            'Reference',
            trailing: _LanguagePicker(controller: controller),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Sb.gutter, 0, Sb.gutter, 20),
            child: reference.isEmpty
                ? Text(
                    '${controller.selectedLanguage} has no community-approved examples yet.',
                    style: const TextStyle(
                      color: Sb.textMuted,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: reference
                        .map(
                          (entry) => Tooltip(
                            message: entry.parameters.join(' · '),
                            child: Chip(
                              label: Text(entry.label),
                              backgroundColor: Sb.surface,
                              side: BorderSide.none,
                              labelStyle: const TextStyle(fontSize: 13),
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showBackupDialog(BuildContext context) async {
    final importController = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          String? error;
          var copied = false;
          return StatefulBuilder(
            builder: (builderContext, setDialogState) => AlertDialog(
              title: const Text('Back up your signs'),
              content: SizedBox(
                width: 460,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text(
                        'Your signs stay on this device. Copy a backup before clearing browser data or moving to another device.',
                        style: TextStyle(
                          color: Sb.textMuted,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: controller.customSigns.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text: controller.exportCustomSignsBackup(),
                                  ),
                                );
                                setDialogState(() => copied = true);
                              },
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        label: Text(copied ? 'Copied' : 'Copy backup'),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: importController,
                        minLines: 4,
                        maxLines: 8,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Paste a backup to restore it',
                        ),
                      ),
                      if (error != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          error!,
                          style: const TextStyle(color: Sb.bad, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      final result = await controller.restoreCustomSignsBackup(
                        importController.text,
                      );
                      if (!dialogContext.mounted) return;
                      Navigator.of(dialogContext).pop();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Restored ${result.restored} sign${result.restored == 1 ? '' : 's'}.',
                            ),
                          ),
                        );
                      }
                    } on FormatException catch (failure) {
                      setDialogState(() => error = failure.message);
                    }
                  },
                  child: const Text('Restore'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      importController.dispose();
    }
  }
}


/// Switching the sign language changes which reference vocabulary and which
/// personal signs apply, so it belongs beside them.
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Sign language',
    initialValue: controller.selectedLanguage,
    onSelected: controller.setLanguage,
    itemBuilder: (context) => SignLexicon.profiles
        .map(
          (profile) => PopupMenuItem<String>(
            value: profile.code,
            child: Text('${profile.code} \u00b7 ${profile.name}'),
          ),
        )
        .toList(growable: false),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Sb.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            controller.selectedLanguage,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Icon(Icons.expand_more, color: Sb.textMuted, size: 17),
        ],
      ),
    ),
  );
}
