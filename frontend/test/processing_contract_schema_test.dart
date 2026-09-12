import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, dynamic> schema;
  late Map<String, dynamic> definitions;
  late Map<String, dynamic> golden;

  setUpAll(() {
    schema = _object(
      jsonDecode(
        File('../processing_contracts.schema.json').readAsStringSync(),
      ),
      'processing schema',
    );
    definitions = _object(schema[r'$defs'], r'$defs');
    golden = _object(
      jsonDecode(
        File('test/fixtures/gloss_lattice_v1.json').readAsStringSync(),
      ),
      'golden GlossLattice',
    );
  });

  test('GlossLattice schema uses the exact frozen wire property sets', () {
    _expectExactObjectShape(definitions, 'glossLattice', const <String>{
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
    _expectExactObjectShape(definitions, 'glossLatticeProducer', const <String>{
      'classifier_id',
      'classifier_version',
      'confidence_kind',
      'calibration_version',
      'vocabulary_version',
    });
    _expectExactObjectShape(definitions, 'glossSlot', const <String>{
      'slot_index',
      'slot_id',
      'start_ms',
      'end_ms',
      'candidates',
      'resolved_gloss_id',
      'provenance',
    });
    _expectExactObjectShape(definitions, 'glossCandidate', const <String>{
      'gloss_id',
      'rank',
      'confidence',
    });
  });

  test('schema freezes backend literals and collection limits', () {
    final lattice = _object(definitions['glossLattice'], 'glossLattice');
    final latticeProperties = _object(
      lattice['properties'],
      'glossLattice.properties',
    );
    final producer = _object(
      definitions['glossLatticeProducer'],
      'glossLatticeProducer',
    );
    final producerProperties = _object(
      producer['properties'],
      'glossLatticeProducer.properties',
    );
    final slot = _object(definitions['glossSlot'], 'glossSlot');
    final slotProperties = _object(slot['properties'], 'glossSlot.properties');
    final candidate = _object(definitions['glossCandidate'], 'glossCandidate');
    final candidateProperties = _object(
      candidate['properties'],
      'glossCandidate.properties',
    );

    expect(
      _object(latticeProperties['type'], 'type')['const'],
      'gloss_lattice',
    );
    expect(
      _object(latticeProperties['schema_version'], 'schema_version')['const'],
      '1.0',
    );
    expect(
      _object(latticeProperties['timebase'], 'timebase')['const'],
      'session_monotonic_ms',
    );
    expect(
      _object(
        producerProperties['confidence_kind'],
        'confidence_kind',
      )['const'],
      'calibrated_probability',
    );

    final slots = _object(latticeProperties['slots'], 'slots');
    expect(slots['minItems'], 1);
    expect(slots['maxItems'], 64);

    final candidates = _object(slotProperties['candidates'], 'candidates');
    expect(candidates['minItems'], 0);
    expect(candidates['maxItems'], 5);

    final rank = _object(candidateProperties['rank'], 'rank');
    expect(rank['minimum'], 1);
    expect(rank['maximum'], 5);
  });

  test('backend golden fixture has exactly the schema wire names', () {
    final producer = _object(golden['producer'], 'golden.producer');
    final slots = _list(golden['slots'], 'golden.slots');

    expect(
      golden.keys.toSet(),
      equals(_propertyNames(definitions, 'glossLattice')),
    );
    expect(
      producer.keys.toSet(),
      equals(_propertyNames(definitions, 'glossLatticeProducer')),
    );

    for (final (slotIndex, slotValue) in slots.indexed) {
      final slot = _object(slotValue, 'golden.slots[$slotIndex]');
      expect(
        slot.keys.toSet(),
        equals(_propertyNames(definitions, 'glossSlot')),
      );

      final candidates = _list(
        slot['candidates'],
        'golden.slots[$slotIndex].candidates',
      );
      for (final (candidateIndex, candidateValue) in candidates.indexed) {
        final candidate = _object(
          candidateValue,
          'golden.slots[$slotIndex].candidates[$candidateIndex]',
        );
        expect(
          candidate.keys.toSet(),
          equals(_propertyNames(definitions, 'glossCandidate')),
        );
      }
    }
  });

  test(
    'legacy and frontend-only data cannot leak into the wire definitions',
    () {
      const forbiddenCandidateKeys = <String>{'score'};
      const forbiddenSlotKeys = <String>{
        'frame_range',
        'frame_index_range',
        'class_scores',
        'confidence',
        'refused',
        'calibrated',
        'segmenter_arm',
        'normalized_coordinates',
        'normalised_coordinates',
        'velocity',
        'acceleration',
        'boundary_events',
        'landmarks',
      };

      expect(
        _propertyNames(
          definitions,
          'glossCandidate',
        ).intersection(forbiddenCandidateKeys),
        isEmpty,
      );
      expect(
        _propertyNames(
          definitions,
          'glossSlot',
        ).intersection(forbiddenSlotKeys),
        isEmpty,
      );
    },
  );
}

Map<String, dynamic> _object(Object? value, String path) {
  if (value is! Map) {
    throw StateError('$path must be a JSON object.');
  }
  return value.cast<String, dynamic>();
}

List<dynamic> _list(Object? value, String path) {
  if (value is! List) {
    throw StateError('$path must be a JSON array.');
  }
  return value;
}

Set<String> _propertyNames(
  Map<String, dynamic> definitions,
  String definitionName,
) {
  final definition = _object(definitions[definitionName], definitionName);
  return _object(
    definition['properties'],
    '$definitionName.properties',
  ).keys.toSet();
}

void _expectExactObjectShape(
  Map<String, dynamic> definitions,
  String definitionName,
  Set<String> expected,
) {
  final definition = _object(definitions[definitionName], definitionName);
  final properties = _object(
    definition['properties'],
    '$definitionName.properties',
  );
  final required = _list(
    definition['required'],
    '$definitionName.required',
  ).cast<String>().toSet();

  expect(properties.keys.toSet(), equals(expected));
  expect(required, equals(expected));
  expect(definition['additionalProperties'], isFalse);
}
