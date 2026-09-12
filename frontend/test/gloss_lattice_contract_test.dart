import 'dart:convert';
import 'dart:io';

import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:flutter_test/flutter_test.dart';

const _latticeKeys = <String>{
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
};

const _producerKeys = <String>{
  'classifier_id',
  'classifier_version',
  'confidence_kind',
  'calibration_version',
  'vocabulary_version',
};

const _slotKeys = <String>{
  'slot_index',
  'slot_id',
  'start_ms',
  'end_ms',
  'candidates',
  'resolved_gloss_id',
  'provenance',
};

const _candidateKeys = <String>{'gloss_id', 'rank', 'confidence'};

void main() {
  late String goldenSource;
  late Map<String, dynamic> golden;

  setUpAll(() {
    goldenSource = File('test/fixtures/gloss_lattice_v1.json')
        .readAsStringSync();
    golden = _decodeObject(goldenSource);
  });

  group('golden contract and frozen constants', () {
    test('golden fixture round-trips without changing any value', () {
      final lattice = GlossLattice.fromWireJson(goldenSource);
      final encoded = lattice.toWireJson();

      expect(jsonDecode(encoded), equals(golden));
      expect(GlossLattice.fromWireJson(encoded).toJson(), equals(golden));
    });

    test('golden fixture has the exact key set at every object level', () {
      expect(golden.keys.toSet(), equals(_latticeKeys));
      expect(_producerOf(golden).keys.toSet(), equals(_producerKeys));

      for (final slot in _slotsOf(golden)) {
        expect(slot.keys.toSet(), equals(_slotKeys));
        for (final candidate in _candidatesOf(slot)) {
          expect(candidate.keys.toSet(), equals(_candidateKeys));
        }
      }
    });

    test('golden fixture exercises every provenance rung', () {
      final lattice = GlossLattice.fromWireJson(goldenSource);

      expect(
        lattice.slots.map((slot) => slot.provenance).toList(),
        equals(const <GlossProvenance>[
          GlossProvenance.classifierHighConfidence,
          GlossProvenance.topKSignerConfirmed,
          GlossProvenance.fingerspelled,
          GlossProvenance.unresolved,
        ]),
      );
      expect(lattice.slots[0].resolvedGlossId, 'WATER');
      expect(lattice.slots[1].resolvedGlossId, 'THANK_YOU');
      expect(lattice.slots[2].resolvedGlossId, 'J-O-H-N');
      expect(lattice.slots[3].resolvedGlossId, isNull);
    });

    test('frozen literals and limits equal CTR version 1.0', () {
      expect(GlossLatticeContract.type, 'gloss_lattice');
      expect(GlossLatticeContract.schemaVersion, '1.0');
      expect(GlossLatticeContract.timebase, 'session_monotonic_ms');
      expect(GlossLatticeContract.confidenceKind, 'calibrated_probability');
      expect(GlossLatticeContract.maxMessageBytes, 32768);
      expect(GlossLatticeContract.maxSlots, 64);
      expect(GlossLatticeContract.maxCandidatesPerSlot, 5);
      expect(GlossLatticeContract.maxSafeJsonInteger, 9007199254740991);
    });
  });

  group('required and unknown properties', () {
    for (final field in _latticeKeys) {
      test('rejects missing GlossLattice.$field', () {
        final payload = _clone(golden)..remove(field);

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('missing required properties'),
        );
      });
    }

    for (final field in _producerKeys) {
      test('rejects missing producer.$field', () {
        final payload = _clone(golden);
        _producerOf(payload).remove(field);

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('missing required properties'),
        );
      });
    }

    for (final field in _slotKeys) {
      test('rejects missing slot.$field', () {
        final payload = _clone(golden);
        _slotsOf(payload).first.remove(field);

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('missing required properties'),
        );
      });
    }

    for (final field in _candidateKeys) {
      test('rejects missing candidate.$field', () {
        final payload = _clone(golden);
        _candidatesOf(_slotsOf(payload).first).first.remove(field);

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('missing required properties'),
        );
      });
    }

    test('resolved_gloss_id is required even when its value is null', () {
      final payload = _clone(golden);
      final unresolved = _slotsOf(payload).last;
      expect(unresolved['resolved_gloss_id'], isNull);
      unresolved.remove('resolved_gloss_id');

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('resolved_gloss_id'),
      );
    });

    test('rejects an unknown envelope property', () {
      final payload = _clone(golden)..['unexpected'] = true;

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('unknown properties'),
      );
    });

    test('rejects an unknown producer property', () {
      final payload = _clone(golden);
      _producerOf(payload)['unexpected'] = true;

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('unknown properties'),
      );
    });

    test('rejects an unknown slot property', () {
      final payload = _clone(golden);
      _slotsOf(payload).first['unexpected'] = true;

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('unknown properties'),
      );
    });

    test('rejects an unknown candidate property', () {
      final payload = _clone(golden);
      _candidatesOf(_slotsOf(payload).first).first['unexpected'] = true;

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('unknown properties'),
      );
    });
  });

  group('legacy and frontend-only properties are forbidden', () {
    const legacyEnvelopeFields = <String>[
      'revision',
      'subject_id',
      'is_final',
      'capture_start_ms',
      'capture_end_ms',
      'produced_ms',
      'quality',
      'landmarks',
      'normalized_coordinates',
      'velocity',
      'acceleration',
      'feature_vector',
    ];
    for (final field in legacyEnvelopeFields) {
      test('rejects legacy envelope field $field', () {
        final payload = _clone(golden)..[field] = 0;

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining(field),
        );
      });
    }

    const legacyProducerFields = <String>[
      'classifier',
      'segmenter',
      'top_k',
      'detector',
    ];
    for (final field in legacyProducerFields) {
      test('rejects legacy producer field $field', () {
        final payload = _clone(golden);
        _producerOf(payload)[field] = 0;

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining(field),
        );
      });
    }

    const legacySlotFields = <String>[
      'frame_range',
      'frame_index_range',
      'class_scores',
      'confidence',
      'refused',
      'calibrated',
      'segmenter_arm',
      'selected_rank',
      'confirmed_at_ms',
      'reason_codes',
      'resolved_gloss',
      'boundary_events',
    ];
    for (final field in legacySlotFields) {
      test('rejects legacy slot field $field', () {
        final payload = _clone(golden);
        _slotsOf(payload).first[field] = 0;

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining(field),
        );
      });
    }

    test('rejects raw score in a wire candidate', () {
      final payload = _clone(golden);
      _candidatesOf(_slotsOf(payload).first).first['score'] = 0.99;

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('score'),
      );
    });

    test('rejects legacy gloss instead of gloss_id', () {
      final payload = _clone(golden);
      final candidate = _candidatesOf(_slotsOf(payload).first).first;
      candidate['gloss'] = candidate.remove('gloss_id');

      expect(
        () => GlossLattice.fromJson(payload),
        _throwsValidationContaining('gloss_id'),
      );
    });
  });

  group('identifier, UUID, literal, and enum rules', () {
    test('identifier accepts the exact 1 and 128 character boundaries', () {
      final oneCharacter = 'A';
      final oneHundredTwentyEight = 'A'.padRight(128, 'z');

      expect(GlossLatticeContract.isValidIdentifier(oneCharacter), isTrue);
      expect(
        GlossLatticeContract.isValidIdentifier(oneHundredTwentyEight),
        isTrue,
      );
      expect(
        () => GlossCandidate(glossId: oneCharacter, rank: 1, confidence: 1),
        returnsNormally,
      );
      expect(
        () => GlossCandidate(
          glossId: oneHundredTwentyEight,
          rank: 1,
          confidence: 1,
        ),
        returnsNormally,
      );
    });

    test('identifier rejects empty, 129-character, and invalid syntax', () {
      final invalid = <String>[
        '',
        'A'.padRight(129, 'z'),
        '_leading',
        '-leading',
        'contains space',
        ' surrounding',
        'trailing ',
        'slash/value',
        r'dollar$value',
        'ÅBC',
        'line\nbreak',
      ];

      for (final value in invalid) {
        expect(
          GlossLatticeContract.isValidIdentifier(value),
          isFalse,
          reason: 'Unexpected valid identifier: ${jsonEncode(value)}',
        );
        expect(
          () => GlossCandidate(glossId: value, rank: 1, confidence: 1),
          _throwsValidationContaining('gloss_id'),
        );
      }
    });

    test('identifier accepts every permitted punctuation character', () {
      const value = 'A_b.C:D-9';

      expect(GlossLatticeContract.isValidIdentifier(value), isTrue);
      expect(
        GlossCandidate(glossId: value, rank: 1, confidence: 1).glossId,
        value,
      );
    });

    test('every identifier-bearing wire location rejects bad syntax', () {
      final mutations = <String, void Function(Map<String, dynamic>)>{
        'utterance_id': (payload) => payload['utterance_id'] = 'bad value',
        'producer.classifier_id': (payload) =>
            _producerOf(payload)['classifier_id'] = 'bad value',
        'producer.classifier_version': (payload) =>
            _producerOf(payload)['classifier_version'] = 'bad value',
        'producer.calibration_version': (payload) =>
            _producerOf(payload)['calibration_version'] = 'bad value',
        'producer.vocabulary_version': (payload) =>
            _producerOf(payload)['vocabulary_version'] = 'bad value',
        'slot_id': (payload) =>
            _slotsOf(payload).first['slot_id'] = 'bad value',
        'candidate.gloss_id': (payload) =>
            _candidatesOf(_slotsOf(payload).first).first['gloss_id'] =
                'bad value',
        'resolved_gloss_id': (payload) =>
            _slotsOf(payload).first['resolved_gloss_id'] = 'bad value',
      };

      for (final mutation in mutations.entries) {
        final payload = _clone(golden);
        mutation.value(payload);
        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidation,
          reason: '${mutation.key} accepted invalid identifier syntax',
        );
      }
    });

    test('session_id accepts a canonical UUID and rejects invalid forms', () {
      const valid = '12345678-1234-5678-1234-567812345678';
      expect(GlossLatticeContract.isValidUuid(valid), isTrue);

      for (final invalid in <String>[
        '',
        '12345678123456781234567812345678',
        '{12345678-1234-5678-1234-567812345678}',
        '12345678-1234-5678-1234-567812345678 ',
        'not-a-uuid',
      ]) {
        final payload = _clone(golden)..['session_id'] = invalid;
        expect(GlossLatticeContract.isValidUuid(invalid), isFalse);
        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('session_id'),
        );
      }
    });

    test('language accepts only sgsl and asl', () {
      expect(
        GlossLatticeLanguage.fromWireValue('sgsl'),
        GlossLatticeLanguage.sgsl,
      );
      expect(
        GlossLatticeLanguage.fromWireValue('asl'),
        GlossLatticeLanguage.asl,
      );

      for (final invalid in <String>['SGSL', 'en', '', ' asl']) {
        final payload = _clone(golden)..['language'] = invalid;
        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('language'),
        );
      }
    });

    test(
      'wire discriminator, version, timebase, and confidence kind are exact',
      () {
        final mutations = <void Function(Map<String, dynamic>)>[
          (payload) => payload['type'] = 'landmark_frame',
          (payload) => payload['schema_version'] = '1.1',
          (payload) => payload['timebase'] = 'unix_epoch_ms',
          (payload) => _producerOf(payload)['confidence_kind'] = 'raw_softmax',
        ];

        for (final mutate in mutations) {
          final payload = _clone(golden);
          mutate(payload);
          expect(() => GlossLattice.fromJson(payload), _throwsValidation);
        }
      },
    );

    test('provenance rejects unsupported values and wrong case', () {
      for (final invalid in <String>[
        'classifier',
        'UNRESOLVED',
        '',
        'unresolved ',
      ]) {
        final payload = _clone(golden);
        _slotsOf(payload).last['provenance'] = invalid;
        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('provenance'),
        );
      }
    });
  });

  group('strict numeric types and scalar boundaries', () {
    test('integer fields reject doubles, numeric strings, and booleans', () {
      final mutations = <String, void Function(Map<String, dynamic>, Object)>{
        'lattice_seq': (payload, value) => payload['lattice_seq'] = value,
        'started_at_ms': (payload, value) => payload['started_at_ms'] = value,
        'ended_at_ms': (payload, value) => payload['ended_at_ms'] = value,
        'slot_index': (payload, value) =>
            _slotsOf(payload).first['slot_index'] = value,
        'start_ms': (payload, value) =>
            _slotsOf(payload).first['start_ms'] = value,
        'end_ms': (payload, value) => _slotsOf(payload).first['end_ms'] = value,
        'candidate.rank': (payload, value) =>
            _candidatesOf(_slotsOf(payload).first).first['rank'] = value,
      };

      for (final mutation in mutations.entries) {
        for (final invalid in <Object>[1.0, '1', true]) {
          final payload = _clone(golden);
          mutation.value(payload, invalid);
          expect(
            () => GlossLattice.fromJson(payload),
            _throwsValidationContaining('integer'),
            reason: '${mutation.key} accepted ${invalid.runtimeType}',
          );
        }
      }
    });

    test('confidence accepts numeric integer endpoints from JSON', () {
      for (final endpoint in <int>[0, 1]) {
        final payload = _clone(golden);
        final candidates = _candidatesOf(_slotsOf(payload).first);
        final candidate = endpoint == 0 ? candidates.last : candidates.first;
        candidate['confidence'] = endpoint;
        final lattice = GlossLattice.fromJson(payload);

        final parsedCandidates = lattice.slots.first.candidates;
        final parsedCandidate = endpoint == 0
            ? parsedCandidates.last
            : parsedCandidates.first;
        expect(parsedCandidate.confidence, endpoint.toDouble());
      }
    });

    test('confidence rejects strings, booleans, and null', () {
      for (final invalid in <Object?>['0.5', true, null]) {
        final payload = _clone(golden);
        _candidatesOf(_slotsOf(payload).first).first['confidence'] = invalid;

        expect(
          () => GlossLattice.fromJson(payload),
          _throwsValidationContaining('number'),
        );
      }
    });

    test(
      'confidence accepts 0 and 1 and rejects non-finite/out-of-range values',
      () {
        for (final valid in <double>[0, 1]) {
          expect(
            () => GlossCandidate(glossId: 'VALID', rank: 1, confidence: valid),
            returnsNormally,
          );
        }

        for (final invalid in <double>[
          -0.000001,
          1.000001,
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
          expect(
            () => GlossCandidate(
              glossId: 'INVALID',
              rank: 1,
              confidence: invalid,
            ),
            _throwsValidationContaining('finite number between 0 and 1'),
          );
        }
      },
    );

    test('safe integer accepts zero and 2^53-1 for lattice_seq', () {
      expect(() => _lattice(latticeSeq: 0), returnsNormally);
      expect(
        () => _lattice(latticeSeq: GlossLatticeContract.maxSafeJsonInteger),
        returnsNormally,
      );
    });

    test('safe integer rejects negative and values above 2^53-1', () {
      expect(
        () => _lattice(latticeSeq: -1),
        _throwsValidationContaining('lattice_seq'),
      );
      expect(
        () => _lattice(latticeSeq: GlossLatticeContract.maxSafeJsonInteger + 1),
        _throwsValidationContaining('lattice_seq'),
      );
      expect(
        () => _slot(startMs: -1, endMs: 1),
        _throwsValidationContaining('start_ms'),
      );
      expect(
        () => _slot(
          startMs: 0,
          endMs: GlossLatticeContract.maxSafeJsonInteger + 1,
        ),
        _throwsValidationContaining('end_ms'),
      );
    });

    test('maximum safe timestamp is valid as an exclusive end', () {
      final maximum = GlossLatticeContract.maxSafeJsonInteger;
      final lattice = _lattice(
        startedAtMs: maximum - 1,
        endedAtMs: maximum,
        slots: <GlossSlot>[_slot(startMs: maximum - 1, endMs: maximum)],
      );

      expect(lattice.endedAtMs, maximum);
    });

    test('candidate rank permits 1 through 5 and rejects 0 and 6', () {
      expect(() => _candidate(rank: 1), returnsNormally);
      expect(() => _candidate(rank: 5), returnsNormally);
      expect(() => _candidate(rank: 0), _throwsValidationContaining('rank'));
      expect(() => _candidate(rank: 6), _throwsValidationContaining('rank'));
    });

    test('slot_index permits 0 through 63 and rejects 64', () {
      expect(() => _slot(slotIndex: 0), returnsNormally);
      expect(() => _slot(slotIndex: 63), returnsNormally);
      expect(
        () => _slot(slotIndex: 64),
        _throwsValidationContaining('slot_index'),
      );
    });
  });

  group('slot and candidate collection constraints', () {
    test('lattice rejects zero slots', () {
      expect(
        () => _lattice(slots: <GlossSlot>[]),
        _throwsValidationContaining('between 1 and 64'),
      );
    });

    test('lattice accepts one slot', () {
      expect(_lattice().slots, hasLength(1));
    });

    test('lattice accepts exactly 64 ordered slots', () {
      final slots = <GlossSlot>[
        for (var index = 0; index < 64; index += 1)
          _slot(
            slotIndex: index,
            slotId: 'slot-$index',
            startMs: index,
            endMs: index + 1,
            candidates: const <GlossCandidate>[],
            resolvedGlossId: null,
            provenance: GlossProvenance.unresolved,
          ),
      ];

      final lattice = _lattice(startedAtMs: 0, endedAtMs: 64, slots: slots);

      expect(lattice.slots, hasLength(64));
    });

    test('lattice rejects 65 slots before accepting invalid array order', () {
      final repeated = List<GlossSlot>.filled(65, _slot(), growable: false);

      expect(
        () => _lattice(slots: repeated),
        _throwsValidationContaining('between 1 and 64'),
      );
    });

    test('slot permits zero candidates for unresolved and fingerspelled', () {
      expect(
        _slot(
          candidates: const <GlossCandidate>[],
          resolvedGlossId: null,
          provenance: GlossProvenance.unresolved,
        ).candidates,
        isEmpty,
      );
      expect(
        _slot(
          candidates: const <GlossCandidate>[],
          resolvedGlossId: 'J-O-H-N',
          provenance: GlossProvenance.fingerspelled,
        ).candidates,
        isEmpty,
      );
    });

    test('slot accepts exactly five candidates', () {
      final candidates = _rankedCandidates(5);
      final slot = _slot(
        candidates: candidates,
        resolvedGlossId: candidates.first.glossId,
      );

      expect(slot.candidates, hasLength(5));
    });

    test('slot rejects six candidates', () {
      final repeated = List<GlossCandidate>.filled(
        6,
        _candidate(),
        growable: false,
      );

      expect(
        () => _slot(candidates: repeated),
        _throwsValidationContaining('more than 5'),
      );
    });

    test('candidate ranks must be contiguous and match array order', () {
      for (final invalid in <List<GlossCandidate>>[
        <GlossCandidate>[_candidate(rank: 2)],
        <GlossCandidate>[
          _candidate(glossId: 'A', rank: 1, confidence: 0.9),
          _candidate(glossId: 'B', rank: 3, confidence: 0.8),
        ],
        <GlossCandidate>[
          _candidate(glossId: 'A', rank: 2, confidence: 0.9),
          _candidate(glossId: 'B', rank: 1, confidence: 0.8),
        ],
      ]) {
        expect(
          () => _slot(
            candidates: invalid,
            resolvedGlossId: invalid.first.glossId,
          ),
          _throwsValidationContaining('contiguous'),
        );
      }
    });

    test('candidate confidence must be non-increasing', () {
      final ascending = <GlossCandidate>[
        _candidate(glossId: 'A', rank: 1, confidence: 0.4),
        _candidate(glossId: 'B', rank: 2, confidence: 0.5),
      ];

      expect(
        () => _slot(candidates: ascending, resolvedGlossId: 'A'),
        _throwsValidationContaining('non-increasing'),
      );
    });

    test('equal confidences and incomplete probability mass are valid', () {
      final candidates = <GlossCandidate>[
        _candidate(glossId: 'A', rank: 1, confidence: 0.4),
        _candidate(glossId: 'B', rank: 2, confidence: 0.4),
      ];

      final slot = _slot(candidates: candidates, resolvedGlossId: 'A');

      expect(
        slot.candidates.fold<double>(0, (sum, item) => sum + item.confidence),
        closeTo(0.8, 1e-12),
      );
    });

    test(
      'candidate gloss IDs must be unique with case-sensitive comparison',
      () {
        final duplicate = <GlossCandidate>[
          _candidate(glossId: 'WATER', rank: 1, confidence: 0.9),
          _candidate(glossId: 'WATER', rank: 2, confidence: 0.8),
        ];
        expect(
          () => _slot(candidates: duplicate, resolvedGlossId: 'WATER'),
          _throwsValidationContaining('unique'),
        );

        final caseDistinct = <GlossCandidate>[
          _candidate(glossId: 'WATER', rank: 1, confidence: 0.9),
          _candidate(glossId: 'water', rank: 2, confidence: 0.8),
        ];
        expect(
          () => _slot(candidates: caseDistinct, resolvedGlossId: 'WATER'),
          returnsNormally,
        );
      },
    );
  });

  group('time, order, and interval invariants', () {
    test('utterance interval must have positive duration', () {
      for (final end in <int>[10, 9]) {
        expect(
          () => _lattice(startedAtMs: 10, endedAtMs: end),
          _throwsValidationContaining('greater than started_at_ms'),
        );
      }
    });

    test('slot interval must have positive duration', () {
      for (final end in <int>[10, 9]) {
        expect(
          () => _slot(startMs: 10, endMs: end),
          _throwsValidationContaining('greater than slot.start_ms'),
        );
      }
    });

    test('every slot must lie inside the utterance interval', () {
      expect(
        () => _lattice(
          startedAtMs: 10,
          endedAtMs: 30,
          slots: <GlossSlot>[_slot(startMs: 9, endMs: 20)],
        ),
        _throwsValidationContaining('inside the utterance interval'),
      );
      expect(
        () => _lattice(
          startedAtMs: 10,
          endedAtMs: 30,
          slots: <GlossSlot>[_slot(startMs: 20, endMs: 31)],
        ),
        _throwsValidationContaining('inside the utterance interval'),
      );
    });

    test('slot indexes are contiguous and equal array order', () {
      final wrongFirst = _slot(slotIndex: 1);
      expect(
        () => _lattice(slots: <GlossSlot>[wrongFirst]),
        _throwsValidationContaining('expected 0'),
      );

      final wrongSecond = <GlossSlot>[
        _slot(slotIndex: 0, slotId: 's0', startMs: 0, endMs: 10),
        _slot(slotIndex: 2, slotId: 's2', startMs: 10, endMs: 20),
      ];
      expect(
        () => _lattice(slots: wrongSecond),
        _throwsValidationContaining('expected 1'),
      );
    });

    test('slot IDs must be unique', () {
      final duplicateIds = <GlossSlot>[
        _slot(slotIndex: 0, slotId: 'same', startMs: 0, endMs: 10),
        _slot(slotIndex: 1, slotId: 'same', startMs: 10, endMs: 20),
      ];

      expect(
        () => _lattice(slots: duplicateIds),
        _throwsValidationContaining('slot_id values must be unique'),
      );
    });

    test('overlapping slot intervals are rejected', () {
      final overlapping = <GlossSlot>[
        _slot(slotIndex: 0, slotId: 's0', startMs: 0, endMs: 20),
        _slot(slotIndex: 1, slotId: 's1', startMs: 19, endMs: 30),
      ];

      expect(
        () => _lattice(slots: overlapping),
        _throwsValidationContaining('non-overlapping'),
      );
    });

    test('half-open adjacent intervals and chronological gaps are valid', () {
      for (final secondStart in <int>[10, 15]) {
        final slots = <GlossSlot>[
          _slot(slotIndex: 0, slotId: 's0', startMs: 0, endMs: 10),
          _slot(slotIndex: 1, slotId: 's1', startMs: secondStart, endMs: 20),
        ];

        expect(() => _lattice(slots: slots), returnsNormally);
      }
    });
  });

  group('provenance and resolution rules', () {
    test('classifier_high_confidence resolves exactly to rank 1', () {
      final candidates = _rankedCandidates(2);
      expect(
        () => _slot(
          candidates: candidates,
          resolvedGlossId: candidates.first.glossId,
        ),
        returnsNormally,
      );
      expect(
        () => _slot(
          candidates: candidates,
          resolvedGlossId: candidates.last.glossId,
        ),
        _throwsValidationContaining('rank-1'),
      );
      expect(
        () =>
            _slot(candidates: const <GlossCandidate>[], resolvedGlossId: null),
        _throwsValidationContaining('at least one candidate'),
      );
      expect(
        () => _slot(candidates: candidates, resolvedGlossId: 'gloss-0'),
        _throwsValidationContaining('rank-1'),
        reason: 'resolution matching must be case-sensitive',
      );
    });

    test('top_k_signer_confirmed resolves to any retained candidate', () {
      final candidates = _rankedCandidates(3);
      expect(
        () => _slot(
          candidates: candidates,
          resolvedGlossId: candidates[1].glossId,
          provenance: GlossProvenance.topKSignerConfirmed,
        ),
        returnsNormally,
      );
      expect(
        () => _slot(
          candidates: candidates,
          resolvedGlossId: null,
          provenance: GlossProvenance.topKSignerConfirmed,
        ),
        _throwsValidationContaining('requires resolved_gloss_id'),
      );
      expect(
        () => _slot(
          candidates: candidates,
          resolvedGlossId: 'NOT_RETAINED',
          provenance: GlossProvenance.topKSignerConfirmed,
        ),
        _throwsValidationContaining('retained candidate'),
      );
    });

    test(
      'fingerspelled requires a resolution but not a retained candidate',
      () {
        expect(
          () => _slot(
            candidates: const <GlossCandidate>[],
            resolvedGlossId: 'J-O-H-N',
            provenance: GlossProvenance.fingerspelled,
          ),
          returnsNormally,
        );
        expect(
          () => _slot(
            candidates: _rankedCandidates(2),
            resolvedGlossId: 'OUTSIDE_TOP_K',
            provenance: GlossProvenance.fingerspelled,
          ),
          returnsNormally,
        );
        expect(
          () => _slot(
            candidates: const <GlossCandidate>[],
            resolvedGlossId: null,
            provenance: GlossProvenance.fingerspelled,
          ),
          _throwsValidationContaining('requires resolved_gloss_id'),
        );
      },
    );

    test('unresolved requires null and may retain low-confidence choices', () {
      expect(
        () => _slot(
          candidates: _rankedCandidates(2, firstConfidence: 0.4),
          resolvedGlossId: null,
          provenance: GlossProvenance.unresolved,
        ),
        returnsNormally,
      );
      expect(
        () => _slot(
          candidates: const <GlossCandidate>[],
          resolvedGlossId: null,
          provenance: GlossProvenance.unresolved,
        ),
        returnsNormally,
      );
      expect(
        () => _slot(
          candidates: _rankedCandidates(1),
          resolvedGlossId: 'GLOSS-0',
          provenance: GlossProvenance.unresolved,
        ),
        _throwsValidationContaining('must have a null'),
      );
    });
  });

  group('wire JSON, byte limit, and immutability', () {
    test('one JSON object is required', () {
      for (final invalid in <String>[
        '[]',
        'null',
        '1',
        '"text"',
        '{} {}',
        '{invalid}',
      ]) {
        expect(
          () => GlossLattice.fromWireJson(invalid),
          _throwsValidation,
          reason: 'Unexpected valid wire input: $invalid',
        );
      }
    });

    test('raw UTF-8 payload accepts 32768 bytes and rejects 32769', () {
      final compact = GlossLattice.fromWireJson(goldenSource).toWireJson();
      final compactBytes = utf8.encode(compact).length;
      expect(compactBytes, lessThan(GlossLatticeContract.maxMessageBytes));
      final atLimit = compact.padRight(
        GlossLatticeContract.maxMessageBytes,
        ' ',
      );

      expect(utf8.encode(atLimit), hasLength(32768));
      expect(() => GlossLattice.fromWireJson(atLimit), returnsNormally);
      expect(
        () => GlossLattice.fromWireJson('$atLimit '),
        _throwsValidationContaining('maximum is 32768'),
      );
    });

    test('constructor rejects compact output larger than 32768 bytes', () {
      final slots = <GlossSlot>[
        for (var slotIndex = 0; slotIndex < 64; slotIndex += 1)
          _slot(
            slotIndex: slotIndex,
            slotId: 'slot-$slotIndex',
            startMs: slotIndex,
            endMs: slotIndex + 1,
            candidates: <GlossCandidate>[
              for (var rank = 1; rank <= 5; rank += 1)
                _candidate(
                  glossId: 'G${slotIndex}_${rank}_'.padRight(128, 'X'),
                  rank: rank,
                  confidence: 1 - ((rank - 1) * 0.1),
                ),
            ],
            resolvedGlossId: 'G${slotIndex}_1_'.padRight(128, 'X'),
          ),
      ];

      expect(
        () => _lattice(startedAtMs: 0, endedAtMs: 64, slots: slots),
        _throwsValidationContaining('maximum is 32768'),
      );
    });

    test(
      'slot defensively copies and exposes an unmodifiable candidate list',
      () {
        final input = <GlossCandidate>[_candidate()];
        final slot = _slot(candidates: input);
        input.clear();

        expect(slot.candidates, hasLength(1));
        expect(
          () => slot.candidates.add(_candidate(glossId: 'OTHER')),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test(
      'lattice defensively copies and exposes an unmodifiable slot list',
      () {
        final input = <GlossSlot>[_slot()];
        final lattice = _lattice(slots: input);
        input.clear();

        expect(lattice.slots, hasLength(1));
        expect(
          () => lattice.slots.add(_slot(slotId: 'other')),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test('serializer retains required null and emits no legacy names', () {
      final lattice = _lattice(
        slots: <GlossSlot>[
          _slot(
            candidates: const <GlossCandidate>[],
            resolvedGlossId: null,
            provenance: GlossProvenance.unresolved,
          ),
        ],
      );
      final json = lattice.toJson();
      final slot = _slotsOf(json).single;

      expect(slot.containsKey('resolved_gloss_id'), isTrue);
      expect(slot['resolved_gloss_id'], isNull);
      expect(json.keys.toSet(), equals(_latticeKeys));
      expect(slot.keys.toSet(), equals(_slotKeys));
      expect(jsonEncode(json), isNot(contains('score')));
      expect(jsonEncode(json), isNot(contains('frame_range')));
      expect(jsonEncode(json), isNot(contains('landmarks')));
    });
  });
}

final Matcher _throwsValidation = throwsA(
  isA<GlossLatticeValidationException>(),
);

Matcher _throwsValidationContaining(String text) => throwsA(
  isA<GlossLatticeValidationException>().having(
    (error) => error.message,
    'message',
    contains(text),
  ),
);

GlossLatticeProducer _producer() => GlossLatticeProducer(
  classifierId: 'temporal_classifier',
  classifierVersion: '1.3.0',
  calibrationVersion: 'temperature_v2',
  vocabularyVersion: 'sgsl_demo_v1',
);

GlossCandidate _candidate({
  String glossId = 'GLOSS-0',
  int rank = 1,
  double confidence = 0.9,
}) => GlossCandidate(glossId: glossId, rank: rank, confidence: confidence);

List<GlossCandidate> _rankedCandidates(
  int count, {
  double firstConfidence = 0.9,
}) => <GlossCandidate>[
  for (var index = 0; index < count; index += 1)
    _candidate(
      glossId: 'GLOSS-$index',
      rank: index + 1,
      confidence: firstConfidence - (index * 0.05),
    ),
];

GlossSlot _slot({
  int slotIndex = 0,
  String slotId = 'slot-0',
  int startMs = 0,
  int endMs = 10,
  List<GlossCandidate>? candidates,
  String? resolvedGlossId = 'GLOSS-0',
  GlossProvenance provenance = GlossProvenance.classifierHighConfidence,
}) => GlossSlot(
  slotIndex: slotIndex,
  slotId: slotId,
  startMs: startMs,
  endMs: endMs,
  candidates: candidates ?? <GlossCandidate>[_candidate()],
  resolvedGlossId: resolvedGlossId,
  provenance: provenance,
);

GlossLattice _lattice({
  String sessionId = '12345678-1234-5678-1234-567812345678',
  int latticeSeq = 0,
  String utteranceId = 'utterance-1',
  GlossLatticeLanguage language = GlossLatticeLanguage.sgsl,
  int startedAtMs = 0,
  int endedAtMs = 100,
  GlossLatticeProducer? producer,
  List<GlossSlot>? slots,
}) => GlossLattice(
  sessionId: sessionId,
  latticeSeq: latticeSeq,
  utteranceId: utteranceId,
  language: language,
  startedAtMs: startedAtMs,
  endedAtMs: endedAtMs,
  producer: producer ?? _producer(),
  slots: slots ?? <GlossSlot>[_slot()],
);

Map<String, dynamic> _decodeObject(String source) =>
    (jsonDecode(source) as Map).cast<String, dynamic>();

Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    _decodeObject(jsonEncode(value));

Map<String, dynamic> _producerOf(Map<String, dynamic> lattice) =>
    (lattice['producer'] as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _slotsOf(Map<String, dynamic> lattice) =>
    (lattice['slots'] as List<dynamic>)
        .map((value) => (value as Map).cast<String, dynamic>())
        .toList(growable: false);

List<Map<String, dynamic>> _candidatesOf(Map<String, dynamic> slot) =>
    (slot['candidates'] as List<dynamic>)
        .map((value) => (value as Map).cast<String, dynamic>())
        .toList(growable: false);
