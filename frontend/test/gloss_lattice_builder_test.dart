import 'package:apptesting/adapters/gloss_lattice_builder.dart';
import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late GlossLatticeProducer producer;
  late GlossLatticeBuilder builder;

  setUp(() {
    producer = GlossLatticeProducer(
      classifierId: 'simplynext_temporal',
      classifierVersion: 'asl_demo_v3',
      calibrationVersion: 'temperature_v2',
      vocabularyVersion: 'demo_v1',
    );
    builder = GlossLatticeBuilder(
      sessionId: '3dd5e15d-991a-4c27-9a11-af4a1a3bb2e8',
      language: GlossLatticeLanguage.asl,
      producer: producer,
    );
  });

  test('maps ordered calibrated classifier output to the exact wire shape', () {
    final lattice = builder.build(
      latticeSeq: 0,
      utteranceId: 'utt-019',
      startedAtMs: 1000,
      endedAtMs: 2000,
      slots: <GlossSlotInput>[
        GlossSlotInput(
          slotId: 'window-12',
          startMs: 1000,
          endMs: 1380,
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
        GlossSlotInput(
          slotId: 'window-13',
          startMs: 1450,
          endMs: 1920,
          candidatesInRankOrder: <CalibratedGlossCandidateInput>[
            CalibratedGlossCandidateInput(
              glossId: 'WATER',
              calibratedConfidence: 0.54,
            ),
            CalibratedGlossCandidateInput(
              glossId: 'DRINK',
              calibratedConfidence: 0.49,
            ),
          ],
          resolvedGlossId: null,
          provenance: GlossProvenance.unresolved,
        ),
      ],
    );

    expect(lattice.latticeSeq, 0);
    expect(lattice.timebase, 'session_monotonic_ms');
    expect(lattice.startedAtMs, 1000);
    expect(lattice.endedAtMs, 2000);
    expect(lattice.slots.map((slot) => slot.slotIndex), <int>[0, 1]);
    expect(
      lattice.slots.first.candidates.map((candidate) => candidate.rank),
      <int>[1, 2],
    );
    expect(
      lattice.slots.first.candidates.map((candidate) => candidate.confidence),
      <double>[0.94, 0.04],
    );

    final json = lattice.toJson();
    expect(json.keys.toSet(), <String>{
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
    _expectForbiddenKeysAbsent(json);
  });

  test('preserves session-monotonic slot times and valid gaps exactly', () {
    final lattice = builder.build(
      latticeSeq: 7,
      utteranceId: 'utt-gap',
      startedAtMs: 500,
      endedAtMs: 2000,
      slots: <GlossSlotInput>[
        _resolvedSlot('first', 500, 700),
        _resolvedSlot('second', 900, 1200),
      ],
    );

    expect(lattice.slots[0].startMs, 500);
    expect(lattice.slots[0].endMs, 700);
    expect(lattice.slots[1].startMs, 900);
    expect(lattice.slots[1].endMs, 1200);
  });

  test('does not silently sort increasing classifier confidence', () {
    expect(
      () => GlossSlotInput(
        slotId: 'bad-order',
        startMs: 10,
        endMs: 20,
        candidatesInRankOrder: <CalibratedGlossCandidateInput>[
          CalibratedGlossCandidateInput(
            glossId: 'LOW',
            calibratedConfidence: 0.2,
          ),
          CalibratedGlossCandidateInput(
            glossId: 'HIGH',
            calibratedConfidence: 0.8,
          ),
        ],
        resolvedGlossId: null,
        provenance: GlossProvenance.unresolved,
      ),
      throwsA(isA<GlossLatticeValidationException>()),
    );
  });

  test('rejects raw or invalid probability before building a payload', () {
    for (final invalid in <double>[double.nan, double.infinity, -0.01, 1.01]) {
      expect(
        () => CalibratedGlossCandidateInput(
          glossId: 'HELLO',
          calibratedConfidence: invalid,
        ),
        throwsA(isA<GlossLatticeValidationException>()),
        reason: '$invalid is not a calibrated probability',
      );
    }
  });

  test('rejects empty, overlapping, and out-of-envelope slot collections', () {
    expect(
      () => builder.build(
        latticeSeq: 1,
        utteranceId: 'empty',
        startedAtMs: 0,
        endedAtMs: 100,
        slots: const <GlossSlotInput>[],
      ),
      throwsA(isA<GlossLatticeValidationException>()),
    );

    expect(
      () => builder.build(
        latticeSeq: 1,
        utteranceId: 'overlap',
        startedAtMs: 0,
        endedAtMs: 100,
        slots: <GlossSlotInput>[
          _resolvedSlot('a', 0, 60),
          _resolvedSlot('b', 59, 90),
        ],
      ),
      throwsA(isA<GlossLatticeValidationException>()),
    );

    expect(
      () => builder.build(
        latticeSeq: 1,
        utteranceId: 'outside',
        startedAtMs: 10,
        endedAtMs: 100,
        slots: <GlossSlotInput>[_resolvedSlot('early', 9, 20)],
      ),
      throwsA(isA<GlossLatticeValidationException>()),
    );
  });

  test('copies mutable Stage 5 input lists at the adapter boundary', () {
    final candidates = <CalibratedGlossCandidateInput>[
      CalibratedGlossCandidateInput(
        glossId: 'HELLO',
        calibratedConfidence: 0.9,
      ),
    ];
    final slot = GlossSlotInput(
      slotId: 'copied',
      startMs: 0,
      endMs: 10,
      candidatesInRankOrder: candidates,
      resolvedGlossId: 'HELLO',
      provenance: GlossProvenance.classifierHighConfidence,
    );

    candidates.clear();

    expect(slot.candidatesInRankOrder, hasLength(1));
    expect(
      () => slot.candidatesInRankOrder.add(
        CalibratedGlossCandidateInput(
          glossId: 'EXTRA',
          calibratedConfidence: 0.1,
        ),
      ),
      throwsUnsupportedError,
    );
  });
}

GlossSlotInput _resolvedSlot(String id, int startMs, int endMs) =>
    GlossSlotInput(
      slotId: id,
      startMs: startMs,
      endMs: endMs,
      candidatesInRankOrder: <CalibratedGlossCandidateInput>[
        CalibratedGlossCandidateInput(
          glossId: 'HELLO_$id',
          calibratedConfidence: 0.9,
        ),
      ],
      resolvedGlossId: 'HELLO_$id',
      provenance: GlossProvenance.classifierHighConfidence,
    );

void _expectForbiddenKeysAbsent(Object? value) {
  const forbidden = <String>{
    'score',
    'frame_range',
    'frame_index_range',
    'class_scores',
    'refused',
    'calibrated',
    'segmenter_arm',
    'normalized_coordinates',
    'normalised_coordinates',
    'velocity',
    'acceleration',
    'boundary_events',
    'landmarks',
    'camera',
  };

  if (value is Map) {
    expect(value.keys.toSet().intersection(forbidden), isEmpty);
    for (final child in value.values) {
      _expectForbiddenKeysAbsent(child);
    }
  } else if (value is Iterable) {
    for (final child in value) {
      _expectForbiddenKeysAbsent(child);
    }
  }
}
