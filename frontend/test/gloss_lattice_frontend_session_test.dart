import 'dart:async';
import 'dart:convert';

import 'package:apptesting/adapters/gloss_lattice_builder.dart';
import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/integration/segmentation_classification_port.dart';
import 'package:apptesting/services/gloss_lattice_connection_factory.dart';
import 'package:apptesting/services/gloss_lattice_frontend_session.dart';
import 'package:apptesting/services/gloss_lattice_session_client.dart';
import 'package:apptesting/services/gloss_lattice_session_coordinator.dart';
import 'package:apptesting/services/gloss_lattice_websocket_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/gloss_lattice_session_fixtures.dart';

void main() {
  test(
    'negotiates, authenticates, builds, and sends through one lifecycle',
    () async {
      Map<String, dynamic>? sessionRequestBody;
      final httpClient = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url, Uri.parse('https://api.example/v1/sessions'));
        sessionRequestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(latticeOnlySessionResponseJson()),
          201,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final sessionClient = GlossLatticeSessionClient(
        baseUri: Uri.parse('https://api.example'),
        client: httpClient,
      );
      addTearDown(sessionClient.close);
      final channel = _SessionChannel();
      Uri? openedUri;
      Map<String, String>? openedHeaders;
      final connectionFactory = GlossLatticeConnectionFactory(
        supportsAuthorizationHeaders: true,
        opener: (uri, headers) async {
          openedUri = uri;
          openedHeaders = headers;
          return channel;
        },
      );
      final clock = GlossLatticeSessionCoordinator.withClock(
        readElapsedMilliseconds: () => 750,
      );

      final frontendSession = await GlossLatticeFrontendSession.connect(
        request: sessionRequest(),
        sessionClient: sessionClient,
        connectionFactory: connectionFactory,
        coordinator: clock,
      );
      addTearDown(frontendSession.close);

      expect(sessionRequestBody?['stream_kind'], 'gloss_lattice');
      expect(sessionRequestBody?['schema_version'], '1.0');
      expect(openedUri, Uri.parse('wss://api.example$latticePath'));
      expect(openedUri.toString(), isNot(contains(streamToken)));
      expect(openedHeaders, <String, String>{
        'Authorization': 'Bearer $streamToken',
      });
      expect(frontendSession.coordinator.nowMs(), 750);

      final receipt = await frontendSession.submissions.submit(
        ClassifiedUtteranceOutput(
          utteranceId: 'utt-1',
          startedAtMs: 750,
          endedAtMs: 1000,
          slots: <GlossSlotInput>[
            GlossSlotInput(
              slotId: 'slot-0',
              startMs: 750,
              endMs: 1000,
              candidatesInRankOrder: <CalibratedGlossCandidateInput>[
                CalibratedGlossCandidateInput(
                  glossId: 'HELLO',
                  calibratedConfidence: 0.93,
                ),
              ],
              resolvedGlossId: 'HELLO',
              provenance: GlossProvenance.classifierHighConfidence,
            ),
          ],
        ),
      );

      expect(receipt.utteranceId, 'utt-1');
      final sent = jsonDecode(channel.sent.single) as Map<String, dynamic>;
      expect(sent['session_id'], sessionId);
      expect(sent['lattice_seq'], 0);
      expect(sent['timebase'], 'session_monotonic_ms');
      expect(sent['producer'], sessionProducer().toJson());
    },
  );
}

final class _SessionChannel implements GlossLatticeTextChannel {
  final StreamController<dynamic> _events = StreamController<dynamic>.broadcast(
    sync: true,
  );
  final List<String> sent = <String>[];
  bool _initialActivityQueued = false;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream {
    if (!_initialActivityQueued) {
      _initialActivityQueued = true;
      scheduleMicrotask(() {
        _events.add(<String, dynamic>{'type': 'activity', 'state': 'idle'});
      });
    }
    return _events.stream;
  }

  @override
  void sendText(String message) {
    sent.add(message);
    final payload = jsonDecode(message) as Map<String, dynamic>;
    scheduleMicrotask(() {
      _events.add(<String, dynamic>{
        'type': 'lattice_ack',
        'lattice_seq': payload['lattice_seq'],
        'utterance_id': payload['utterance_id'],
        'disposition': 'accepted',
      });
      _events.add(<String, dynamic>{
        'type': 'lattice_result',
        'lattice_seq': payload['lattice_seq'],
        'utterance_id': payload['utterance_id'],
        'status': 'confident',
        'caption': 'Hello.',
        'tts_text': 'Hello.',
        'confidence': 0.93,
        'gloss_id_trace': <String>['HELLO'],
      });
    });
  }

  @override
  Future<void> close() => _events.close();
}
