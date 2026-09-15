import 'dart:async';
import 'dart:convert';

import 'package:apptesting/adapters/gloss_lattice_builder.dart';
import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/integration/segmentation_classification_port.dart';
import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/frontend_pipeline_coordinator.dart';
import 'package:apptesting/services/gloss_lattice_submission_service.dart';
import 'package:apptesting/services/gloss_lattice_session_coordinator.dart';
import 'package:apptesting/services/gloss_lattice_websocket_client.dart';
import 'package:apptesting/services/state_normalised_tracking_service.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:apptesting/services/tracking_state_normalisation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/landmark_frame_fixtures.dart';

const _sessionId = '12345678-1234-5678-1234-567812345678';
final _producer = GlossLatticeProducer(
  classifierId: 'esther_temporal',
  classifierVersion: 'sgsl_v1',
  confidenceKind: 'calibrated_probability',
  calibrationVersion: 'temperature_v1',
  vocabularyVersion: 'sgsl_demo_v1',
);

void main() {
  test(
    'Harold frame -> Stage 3/4 -> Esther seam -> exact GlossLattice WebSocket',
    () async {
      final upstream = _FakeTrackingService();
      final tracking = StateNormalisedTrackingService(upstream);
      final recognition = _FakeSegmentationClassificationPort();
      final channel = _RespondingTextChannel();
      final websocket = GlossLatticeWebSocketClient(
        channel: channel,
        sessionId: _sessionId,
      );
      final submissions = GlossLatticeSubmissionService(
        builder: GlossLatticeBuilder(
          sessionId: _sessionId,
          language: GlossLatticeLanguage.sgsl,
          producer: _producer,
        ),
        websocketClient: websocket,
        sessionCoordinator: GlossLatticeSessionCoordinator.withClock(
          readElapsedMilliseconds: () => 1000,
          wallClockOrigin: LandmarkFrameFixtures.epoch.subtract(
            const Duration(milliseconds: 1000),
          ),
        ),
      );
      final pipeline = FrontendPipelineCoordinator(
        tracking: tracking,
        recognition: recognition,
        submissions: submissions,
      );
      addTearDown(pipeline.close);
      await pipeline.start();

      upstream.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
      await Future<void>.delayed(Duration.zero);

      expect(recognition.frames, hasLength(1));
      final stageFiveInput = recognition.frames.single;
      expect(stageFiveInput.trackingState?.status.name, 'tracked');
      expect(stageFiveInput.normalisation?.canNormalise, isTrue);
      expect(stageFiveInput.normalisation?.hands, hasLength(2));
      expect(recognition.sessionTimestampsMs, <int>[1000]);

      final receiptFuture = pipeline.receipts.first;
      recognition.emit(_classifiedUtterance('utt-0'));
      final receipt = await receiptFuture;

      expect(receipt.wasCached, isFalse);
      expect(receipt.requiresRepair, isFalse);
      expect(channel.sentText, hasLength(1));
      final wire = jsonDecode(channel.sentText.single) as Map<String, dynamic>;
      expect(wire.keys.toSet(), <String>{
        'type',
        'schema_version',
        'session_id',
        'lattice_seq',
        'utterance_id',
        'language',
        'timebase',
        'started_at_ms',
        'ended_at_ms',
        'producer',
        'slots',
      });
      expect(wire['session_id'], _sessionId);
      expect(wire['lattice_seq'], 0);
      expect(wire['utterance_id'], 'utt-0');
      expect(wire['language'], 'sgsl');
      expect(wire['timebase'], 'session_monotonic_ms');
      expect(wire['started_at_ms'], 1000);
      expect(wire['ended_at_ms'], 1400);
      expect(wire, isNot(contains('landmarks')));
      expect(wire, isNot(contains('normalisation')));
      expect(wire, isNot(contains('feature_vector')));

      final slot =
          (wire['slots'] as List<dynamic>).single as Map<String, dynamic>;
      expect(slot['slot_index'], 0);
      expect(slot['slot_id'], 'slot-0');
      expect(slot['start_ms'], 1000);
      expect(slot['end_ms'], 1400);
      expect(slot['resolved_gloss_id'], 'HELLO');
      expect(slot['provenance'], 'classifier_high_confidence');
      expect(slot.keys, isNot(contains('score')));
      final candidates = slot['candidates'] as List<dynamic>;
      expect(candidates, <Object?>[
        <String, Object?>{'gloss_id': 'HELLO', 'rank': 1, 'confidence': 0.94},
        <String, Object?>{'gloss_id': 'WELCOME', 'rank': 2, 'confidence': 0.04},
      ]);
    },
  );

  test(
    'successful frontend submissions use monotonic lattice sequences',
    () async {
      final channel = _RespondingTextChannel();
      final service = _submissionService(channel);
      addTearDown(service.close);

      await service.submit(_classifiedUtterance('utt-0'));
      await service.submit(_classifiedUtterance('utt-1'));

      final payloads = channel.sentText
          .map((text) => jsonDecode(text) as Map<String, dynamic>)
          .toList();
      expect(payloads.map((item) => item['lattice_seq']), <Object?>[0, 1]);
      expect(payloads.map((item) => item['utterance_id']), <Object?>[
        'utt-0',
        'utt-1',
      ]);
      expect(service.pendingLattice, isNull);
    },
  );

  test(
    'failed send keeps identical bytes and sequence for explicit retry',
    () async {
      final channel = _RespondingTextChannel(failFirstSend: true);
      final service = _submissionService(channel);
      addTearDown(service.close);

      await expectLater(
        service.submit(_classifiedUtterance('utt-retry')),
        throwsA(isA<GlossLatticeWebSocketException>()),
      );
      expect(service.pendingLattice?.latticeSeq, 0);
      await expectLater(
        service.submit(_classifiedUtterance('utt-new')),
        throwsStateError,
      );

      final receipt = await service.retryPending();

      expect(receipt.utteranceId, 'utt-retry');
      expect(channel.sentText, hasLength(2));
      expect(channel.sentText[1], channel.sentText[0]);
      expect(service.pendingLattice, isNull);
    },
  );

  test('reconnect retries the pending lattice as identical bytes', () async {
    final disconnected = _RespondingTextChannel(failFirstSend: true);
    final service = _submissionService(disconnected);
    addTearDown(service.close);

    await expectLater(
      service.submit(_classifiedUtterance('utt-reconnect')),
      throwsA(isA<GlossLatticeWebSocketException>()),
    );
    final replacement = _RespondingTextChannel();
    await service.replaceWebsocketClient(
      GlossLatticeWebSocketClient(channel: replacement, sessionId: _sessionId),
    );

    final receipt = await service.retryPending();

    expect(receipt.utteranceId, 'utt-reconnect');
    expect(disconnected.sentText, hasLength(1));
    expect(replacement.sentText, hasLength(1));
    expect(replacement.sentText.single, disconnected.sentText.single);
  });

  test('coordinator rejects a raw frame that bypasses Stage 3/4', () async {
    final rawTracking = _FakeTrackingService();
    final recognition = _FakeSegmentationClassificationPort();
    final service = _submissionService(_RespondingTextChannel());
    final pipeline = FrontendPipelineCoordinator(
      tracking: rawTracking,
      recognition: recognition,
      submissions: service,
    );
    addTearDown(pipeline.close);
    await pipeline.start();
    final errorFuture = pipeline.receipts.first;

    rawTracking.ingest(LandmarkFrameFixtures.fullyTrackedFrame());

    await expectLater(errorFuture, throwsStateError);
    expect(recognition.frames, isEmpty);
  });

  test('stop then start creates one fresh set of subscriptions', () async {
    final tracking = _FakeTrackingService();
    final recognition = _FakeSegmentationClassificationPort();
    final pipeline = FrontendPipelineCoordinator(
      tracking: tracking,
      recognition: recognition,
      submissions: _submissionService(_RespondingTextChannel()),
    );
    addTearDown(pipeline.close);

    await pipeline.start();
    tracking.ingest(_processedFrame());
    expect(recognition.frames, hasLength(1));

    await pipeline.stop();
    expect(recognition.resetCount, 1);
    tracking.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
    expect(recognition.frames, hasLength(1));

    await pipeline.start();
    tracking.ingest(_processedFrame());

    expect(recognition.frames, hasLength(2));
  });
}

LandmarkFrame _processedFrame() => TrackingStateNormalisationService().process(
  LandmarkFrameFixtures.fullyTrackedFrame(),
);

GlossLatticeSubmissionService _submissionService(
  _RespondingTextChannel channel,
) => GlossLatticeSubmissionService(
  builder: GlossLatticeBuilder(
    sessionId: _sessionId,
    language: GlossLatticeLanguage.sgsl,
    producer: _producer,
  ),
  websocketClient: GlossLatticeWebSocketClient(
    channel: channel,
    sessionId: _sessionId,
  ),
  sessionCoordinator: GlossLatticeSessionCoordinator.withClock(
    readElapsedMilliseconds: () => 1000,
    wallClockOrigin: LandmarkFrameFixtures.epoch.subtract(
      const Duration(milliseconds: 1000),
    ),
  ),
);

ClassifiedUtteranceOutput _classifiedUtterance(String utteranceId) =>
    ClassifiedUtteranceOutput(
      utteranceId: utteranceId,
      startedAtMs: 1000,
      endedAtMs: 1400,
      slots: <GlossSlotInput>[
        GlossSlotInput(
          slotId: 'slot-0',
          startMs: 1000,
          endMs: 1400,
          candidatesInRankOrder: <CalibratedGlossCandidateInput>[
            CalibratedGlossCandidateInput(
              glossId: 'HELLO',
              calibratedConfidence: 0.94,
            ),
            CalibratedGlossCandidateInput(
              glossId: 'WELCOME',
              calibratedConfidence: 0.04,
            ),
          ],
          resolvedGlossId: 'HELLO',
          provenance: GlossProvenance.classifierHighConfidence,
        ),
      ],
    );

final class _RespondingTextChannel implements GlossLatticeTextChannel {
  _RespondingTextChannel({this.failFirstSend = false});

  final bool failFirstSend;
  final StreamController<dynamic> _responses =
      StreamController<dynamic>.broadcast(sync: true);
  final List<String> sentText = <String>[];
  bool _failed = false;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _responses.stream;

  @override
  void sendText(String message) {
    sentText.add(message);
    final lattice = jsonDecode(message) as Map<String, dynamic>;
    scheduleMicrotask(() {
      if (failFirstSend && !_failed) {
        _failed = true;
        _responses.add(<String, dynamic>{
          'type': 'error',
          'code': 'temporary_capacity',
          'message': 'Try again.',
          'retryable': true,
        });
        return;
      }
      _responses.add(<String, dynamic>{
        'type': 'lattice_ack',
        'lattice_seq': lattice['lattice_seq'],
        'utterance_id': lattice['utterance_id'],
        'disposition': 'accepted',
      });
      _responses.add(<String, dynamic>{
        'type': 'lattice_result',
        'lattice_seq': lattice['lattice_seq'],
        'utterance_id': lattice['utterance_id'],
        'status': 'confident',
        'caption': 'Hello.',
        'tts_text': 'Hello.',
        'confidence': 0.94,
        'gloss_id_trace': <String>['HELLO'],
      });
    });
  }

  @override
  Future<void> close() => _responses.close();
}

final class _FakeSegmentationClassificationPort
    implements SegmentationClassificationPort {
  final StreamController<ClassifiedUtteranceOutput> _outputs =
      StreamController<ClassifiedUtteranceOutput>.broadcast(sync: true);
  final List<LandmarkFrame> frames = <LandmarkFrame>[];
  final List<int> sessionTimestampsMs = <int>[];
  int resetCount = 0;

  @override
  Stream<ClassifiedUtteranceOutput> get completedUtterances => _outputs.stream;

  @override
  void addNormalisedFrame(
    LandmarkFrame frame, {
    required int sessionTimestampMs,
  }) {
    frames.add(frame);
    sessionTimestampsMs.add(sessionTimestampMs);
  }

  void emit(ClassifiedUtteranceOutput output) => _outputs.add(output);

  @override
  Future<void> reset() async {
    resetCount += 1;
  }

  @override
  Future<void> close() => _outputs.close();
}

final class _FakeTrackingService implements TrackingService {
  final StreamController<LandmarkFrame> _frames =
      StreamController<LandmarkFrame>.broadcast(sync: true);
  final TrackingSampleBuffer _confidence = TrackingSampleBuffer();
  final List<LandmarkFrame> _recent = <LandmarkFrame>[];
  final List<LandmarkFrame> _utterance = <LandmarkFrame>[];
  LandmarkFrame? _latest;
  bool _capturing = false;

  @override
  Stream<LandmarkFrame> get frames => _frames.stream;
  @override
  LandmarkFrame? get latestFrame => _latest;
  @override
  TrackingSampleBuffer get confidenceWindow => _confidence;
  @override
  List<LandmarkFrame> get recentFrames => List.unmodifiable(_recent);
  @override
  List<LandmarkFrame> get utteranceFrames => List.unmodifiable(_utterance);
  @override
  int get utteranceFrameCount => _utterance.length;
  @override
  bool get isCapturingUtterance => _capturing;
  @override
  String get status => 'fake';
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async => _capturing = false;
  @override
  void beginUtterance() {
    _utterance.clear();
    _capturing = true;
  }

  @override
  Future<List<LandmarkFrame>> finishUtterance() async {
    _capturing = false;
    final result = List<LandmarkFrame>.unmodifiable(_utterance);
    _utterance.clear();
    return result;
  }

  @override
  void ingest(LandmarkFrame frame) {
    _latest = frame;
    _recent.add(frame);
    if (_capturing) _utterance.add(frame);
    _confidence.add(frame.trackingConfidence, frame.timestamp);
    _frames.add(frame);
  }

  @override
  void dispose() => unawaited(_frames.close());
}
