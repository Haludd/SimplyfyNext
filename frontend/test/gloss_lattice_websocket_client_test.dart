import 'dart:async';
import 'dart:convert';

import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/services/gloss_lattice_websocket_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeTextChannel channel;
  late GlossLatticeWebSocketClient client;

  setUp(() {
    channel = _FakeTextChannel();
    client = GlossLatticeWebSocketClient(
      channel: channel,
      sessionId: _sessionId,
    );
  });

  tearDown(() async {
    await client.close();
  });

  test('sends one unchanged compact GlossLattice text frame', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);

    expect(channel.sentMessages, <String>[lattice.toWireJson()]);
    expect(channel.sentMessages.single.contains('\n'), isFalse);
    expect(jsonDecode(channel.sentMessages.single), lattice.toJson());

    channel.addJson(<String, dynamic>{
      'type': 'activity',
      'state': 'processing',
    });
    channel.addJson(_ack(lattice));
    channel.addJson(_result(lattice));

    final receipt = await submission;
    expect(receipt.latticeSeq, lattice.latticeSeq);
    expect(receipt.utteranceId, lattice.utteranceId);
    expect(receipt.wasCached, isFalse);
    expect(receipt.requiresRepair, isFalse);
  });

  test('accepts cached acknowledgement and repair terminal response', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);

    channel.addJson(<String, dynamic>{
      ..._ack(lattice),
      'disposition': 'cached',
    });
    channel.addJson(<String, dynamic>{
      'type': 'lattice_repair_required',
      'lattice_seq': lattice.latticeSeq,
      'utterance_id': lattice.utteranceId,
      'status': 'uncertain',
    });

    final receipt = await submission;
    expect(receipt.wasCached, isTrue);
    expect(receipt.requiresRepair, isTrue);
  });

  test('allows an exact retry without changing its bytes', () async {
    final lattice = _lattice();

    final first = client.send(lattice);
    await _waitForSentCount(channel, 1);
    channel.addJson(_ack(lattice));
    channel.addJson(_result(lattice));
    await first;

    final retry = client.send(lattice);
    await _waitForSentCount(channel, 2);
    channel.addJson(<String, dynamic>{
      ..._ack(lattice),
      'disposition': 'cached',
    });
    channel.addJson(_result(lattice));
    await retry;

    expect(channel.sentMessages, hasLength(2));
    expect(channel.sentMessages[1], channel.sentMessages[0]);
  });

  test('rejects a lattice for another session before sending', () async {
    final other = _lattice(sessionId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');

    await expectLater(
      client.send(other),
      throwsA(
        isA<GlossLatticeWebSocketException>().having(
          (error) => error.code,
          'code',
          'session_mismatch',
        ),
      ),
    );
    expect(channel.sentMessages, isEmpty);
  });

  test('turns a backend error event into a typed exception', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);
    channel.addJson(<String, dynamic>{
      'type': 'error',
      'code': 'invalid_message',
      'message': 'The lattice is invalid.',
      'retryable': false,
    });

    await expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>()
            .having((error) => error.code, 'code', 'invalid_message')
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
  });

  test('rejects a terminal response before its acknowledgement', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);
    channel.addJson(_result(lattice));

    await expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('rejects mismatched acknowledgement correlation', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);
    channel.addJson(<String, dynamic>{
      ..._ack(lattice),
      'lattice_seq': lattice.latticeSeq + 1,
    });

    await expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>().having(
          (error) => error.code,
          'code',
          'correlation_mismatch',
        ),
      ),
    );
  });

  test('accepts matching optional event envelope fields', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);

    channel.addJson(<String, dynamic>{
      'type': 'activity',
      'event_schema_version': GlossLatticeContract.schemaVersion,
      'session_id': _sessionId,
      'state': 'processing',
      'lattice_seq': lattice.latticeSeq,
      'utterance_id': lattice.utteranceId,
      'server_ms': 5000,
    });
    channel.addJson(<String, dynamic>{
      ..._ack(lattice),
      'event_schema_version': GlossLatticeContract.schemaVersion,
      'session_id': _sessionId,
    });
    channel.addJson(<String, dynamic>{
      ..._result(lattice),
      'event_schema_version': GlossLatticeContract.schemaVersion,
      'session_id': _sessionId,
      'tts_text': 'Water',
      'gloss_id_trace': <String>['WATER'],
      'evidence_trace': <Map<String, dynamic>>[
        <String, dynamic>{
          'slot_index': 0,
          'slot_id': lattice.slots.single.slotId,
          'start_ms': lattice.slots.single.startMs,
          'end_ms': lattice.slots.single.endMs,
          'resolved_gloss_id': lattice.slots.single.resolvedGlossId,
          'confidence': lattice.slots.single.candidates.single.confidence,
          'provenance': lattice.slots.single.provenance.wireValue,
          'candidates': lattice.slots.single.candidates
              .map((candidate) => candidate.toJson())
              .toList(),
        },
      ],
      'classifier_version': '1.3.0',
      'agent_source': 'exact_template',
      'agent_model_version': null,
      'latency_ms': <String, dynamic>{'total': 1},
    });

    final receipt = await submission;
    expect(receipt.latticeSeq, lattice.latticeSeq);
    expect(receipt.requiresRepair, isFalse);
  });

  test('rejects an event belonging to another session', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);

    channel.addJson(<String, dynamic>{
      ..._ack(lattice),
      'event_schema_version': GlossLatticeContract.schemaVersion,
      'session_id': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
    });

    await expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>().having(
          (error) => error.code,
          'code',
          'correlation_mismatch',
        ),
      ),
    );
  });

  test('rejects an unsupported backend event schema version', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);

    channel.addJson(<String, dynamic>{
      'type': 'activity',
      'event_schema_version': '2.0',
      'session_id': _sessionId,
      'state': 'processing',
    });

    await expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('prevents two submissions from sharing one response sequence', () async {
    final lattice = _lattice();
    final first = client.send(lattice);
    await _waitForSentMessage(channel);

    await expectLater(client.send(lattice), throwsStateError);
    expect(channel.sentMessages, hasLength(1));

    channel.addJson(_ack(lattice));
    channel.addJson(_result(lattice));
    await first;
  });

  test('reports a closed response stream as retryable', () async {
    final lattice = _lattice();
    final submission = client.send(lattice);
    await _waitForSentMessage(channel);
    final expectation = expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>()
            .having((error) => error.code, 'code', 'connection_closed')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
    await channel.closeIncoming();
    await expectation;
  });

  test('turns a silent response stream into a retryable timeout', () async {
    await client.close();
    channel = _FakeTextChannel();
    client = GlossLatticeWebSocketClient(
      channel: channel,
      sessionId: _sessionId,
      responseTimeout: const Duration(milliseconds: 5),
    );

    final submission = client.send(_lattice());
    await _waitForSentMessage(channel);

    await expectLater(
      submission,
      throwsA(
        isA<GlossLatticeWebSocketException>()
            .having((error) => error.code, 'code', 'response_timeout')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('close is idempotent and prevents later sends', () async {
    await client.close();
    await client.close();

    expect(channel.closeCount, 1);
    await expectLater(client.send(_lattice()), throwsStateError);
  });
}

const _sessionId = '12345678-1234-5678-1234-567812345678';

GlossLattice _lattice({String sessionId = _sessionId}) => GlossLattice(
  sessionId: sessionId,
  latticeSeq: 7,
  utteranceId: 'utterance-42',
  language: GlossLatticeLanguage.sgsl,
  startedAtMs: 1000,
  endedAtMs: 1300,
  producer: GlossLatticeProducer(
    classifierId: 'temporal_classifier',
    classifierVersion: '1.3.0',
    calibrationVersion: 'temperature_v2',
    vocabularyVersion: 'sgsl_demo_v1',
  ),
  slots: <GlossSlot>[
    GlossSlot(
      slotIndex: 0,
      slotId: 'slot-0',
      startMs: 1000,
      endMs: 1300,
      candidates: <GlossCandidate>[
        GlossCandidate(glossId: 'WATER', rank: 1, confidence: 0.96),
      ],
      resolvedGlossId: 'WATER',
      provenance: GlossProvenance.classifierHighConfidence,
    ),
  ],
);

Map<String, dynamic> _ack(GlossLattice lattice) => <String, dynamic>{
  'type': 'lattice_ack',
  'lattice_seq': lattice.latticeSeq,
  'utterance_id': lattice.utteranceId,
  'disposition': 'accepted',
  'server_ms': 5000,
};

Map<String, dynamic> _result(GlossLattice lattice) => <String, dynamic>{
  'type': 'lattice_result',
  'lattice_seq': lattice.latticeSeq,
  'utterance_id': lattice.utteranceId,
  'status': 'confident',
  'caption': 'Water',
  'confidence': 0.96,
};

Future<void> _waitForSentMessage(_FakeTextChannel channel) =>
    _waitForSentCount(channel, 1);

Future<void> _waitForSentCount(_FakeTextChannel channel, int count) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (channel.sentMessages.length >= count) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(
    'Expected $count WebSocket message(s), found '
    '${channel.sentMessages.length}.',
  );
}

final class _FakeTextChannel implements GlossLatticeTextChannel {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  final List<String> sentMessages = <String>[];
  int closeCount = 0;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void sendText(String message) => sentMessages.add(message);

  void addJson(Map<String, dynamic> value) {
    _incoming.add(jsonEncode(value));
  }

  Future<void> closeIncoming() => _incoming.close();

  @override
  Future<void> close() async {
    closeCount += 1;
    if (!_incoming.isClosed) await _incoming.close();
  }
}
