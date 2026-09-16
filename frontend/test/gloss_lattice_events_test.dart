import 'package:apptesting/contracts/gloss_lattice_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a versioned lattice result and preserves evidence', () {
    final event = GlossLatticeBackendEvent.fromJson(<String, dynamic>{
      'type': 'lattice_result',
      'event_schema_version': '1.0',
      'session_id': '12345678-1234-5678-1234-567812345678',
      'lattice_seq': 7,
      'utterance_id': 'utt-019',
      'status': 'confident',
      'caption': 'Water',
      'tts_text': 'Water',
      'confidence': 0.94,
      'gloss_id_trace': <String>['WATER'],
      'evidence_trace': <Map<String, dynamic>>[
        <String, dynamic>{
          'slot_index': 0,
          'slot_id': 's0',
          'start_ms': 1000,
          'end_ms': 1380,
          'resolved_gloss_id': 'WATER',
          'confidence': 0.94,
          'provenance': 'classifier_high_confidence',
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'gloss_id': 'WATER',
              'rank': 1,
              'confidence': 0.94,
            },
          ],
        },
      ],
      'classifier_version': 'asl_demo_v3',
      'agent_source': 'exact_template',
      'agent_model_version': null,
      'latency_ms': <String, dynamic>{'total': 2},
    });

    expect(event, isA<GlossLatticeResultEvent>());
    final result = event as GlossLatticeResultEvent;
    expect(result.caption, 'Water');
    expect(result.glossIdTrace, <String>['WATER']);
    expect(result.evidenceTrace.single.slotId, 's0');
  });

  test('rejects unknown event types and schema versions', () {
    expect(
      () => GlossLatticeBackendEvent.fromJson(<String, dynamic>{
        'type': 'future_event',
      }),
      throwsA(isA<GlossLatticeEventValidationException>()),
    );
    expect(
      () => GlossLatticeBackendEvent.fromJson(<String, dynamic>{
        'type': 'activity',
        'event_schema_version': '2.0',
        'session_id': '12345678-1234-5678-1234-567812345678',
        'state': 'idle',
        'lattice_seq': null,
        'utterance_id': null,
        'server_ms': 1,
      }),
      throwsA(isA<GlossLatticeEventValidationException>()),
    );
  });
}
