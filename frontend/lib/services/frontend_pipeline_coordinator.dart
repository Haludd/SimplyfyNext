import 'dart:async';

import '../integration/segmentation_classification_port.dart';
import '../models/tracking_models.dart';
import 'gloss_lattice_submission_service.dart';
import 'gloss_lattice_websocket_client.dart';
import 'tracking_service.dart';

/// Connects the implemented frontend stages without owning any stage logic.
///
/// [tracking] must expose Stage 3/4 processed frames (normally through
/// `StateNormalisedTrackingService`). [recognition] is supplied by Esther's
/// Stage 5/6 implementation. Only its completed symbolic output reaches the
/// WebSocket submission service.
final class FrontendPipelineCoordinator {
  FrontendPipelineCoordinator({
    required this.tracking,
    required this.recognition,
    required this.submissions,
  });

  final TrackingService tracking;
  final SegmentationClassificationPort recognition;
  final GlossLatticeSubmissionService submissions;

  final StreamController<GlossLatticeSubmissionReceipt> _receipts =
      StreamController<GlossLatticeSubmissionReceipt>.broadcast();
  StreamSubscription<LandmarkFrame>? _frameSubscription;
  StreamSubscription<ClassifiedUtteranceOutput>? _outputSubscription;
  Future<void> _deliveryTail = Future<void>.value();
  bool _started = false;
  bool _closed = false;

  Stream<GlossLatticeSubmissionReceipt> get receipts => _receipts.stream;

  Future<void> start() async {
    if (_closed) throw StateError('FrontendPipelineCoordinator is closed.');
    if (_started) return;
    _started = true;
    _frameSubscription = tracking.frames.listen(
      _onProcessedFrame,
      onError: _forwardError,
    );
    _outputSubscription = recognition.completedUtterances.listen(
      _queueClassifiedOutput,
      onError: _forwardError,
    );
    try {
      await tracking.start();
    } catch (_) {
      await _frameSubscription?.cancel();
      await _outputSubscription?.cancel();
      _frameSubscription = null;
      _outputSubscription = null;
      _started = false;
      rethrow;
    }
  }

  void _onProcessedFrame(LandmarkFrame frame) {
    if (!_started || _closed) return;
    if (frame.trackingState == null || frame.normalisation == null) {
      _forwardError(
        StateError(
          'Stage 5 received a frame before tracking state and normalisation.',
        ),
      );
      return;
    }
    try {
      recognition.addNormalisedFrame(
        frame,
        sessionTimestampMs: submissions.sessionCoordinator.captureTimestampMs(
          frame.timestamp,
        ),
      );
    } catch (error, stackTrace) {
      _forwardError(error, stackTrace);
    }
  }

  void _queueClassifiedOutput(ClassifiedUtteranceOutput output) {
    if (!_started || _closed) return;
    _deliveryTail = _deliveryTail.then((_) async {
      try {
        final receipt = await submissions.submit(output);
        if (!_receipts.isClosed) _receipts.add(receipt);
      } catch (error, stackTrace) {
        if (!_receipts.isClosed) _receipts.addError(error, stackTrace);
      }
    });
  }

  void _forwardError(Object error, [StackTrace? stackTrace]) {
    if (_receipts.isClosed) return;
    _receipts.addError(error, stackTrace ?? StackTrace.current);
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    final frameSubscription = _frameSubscription;
    final outputSubscription = _outputSubscription;
    _frameSubscription = null;
    _outputSubscription = null;
    await frameSubscription?.cancel();
    await outputSubscription?.cancel();
    try {
      await tracking.stop();
      await _deliveryTail;
    } finally {
      await recognition.reset();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await stop();
    await _frameSubscription?.cancel();
    await _outputSubscription?.cancel();
    await recognition.close();
    await submissions.close();
    await _receipts.close();
  }
}
