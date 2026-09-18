import 'dart:convert';
import 'dart:io';

import 'package:apptesting/config/room_client_config.dart';
import 'package:apptesting/contracts/translated_sign_utterance.dart';
import 'package:apptesting/models/room_models.dart';
import 'package:apptesting/services/room_session_controller.dart';
import 'package:apptesting/services/room_session_storage.dart';
import 'package:apptesting/services/translated_sign_utterance_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'room text and sign messages share one authenticated sequence',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/v1/rooms') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'utterance_schema_version': '1.0',
              'code': 'ABCDEFGH',
              'participant_id': '11111111-1111-4111-8111-111111111111',
              'role': 'signer',
              'token': 'participant-secret',
              'join_path': '/?room=ABCDEFGH',
            }),
            201,
          );
        }
        expect(request.headers['authorization'], 'Bearer participant-secret');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (path.endsWith('/messages')) {
          expect(body['client_sequence'], 0);
          expect(body['source'], 'speech');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'message_id': body['message_id'],
              'sender_id': '11111111-1111-4111-8111-111111111111',
              'client_sequence': 0,
              'server_sequence': 0,
              'context_version': 1,
              'source': 'speech',
              'status': 'accepted',
              'text': body['text'],
            }),
            201,
          );
        }
        if (path.endsWith('/sign-utterances')) {
          expect(body['client_sequence'], 1);
          expect(body.keys, containsAll(<String>['producer', 'words']));
          expect(body.keys, isNot(contains('landmarks')));
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'type': 'utterance_ack',
              'message_id': body['message_id'],
              'client_sequence': 1,
              'server_sequence': 1,
              'disposition': 'accepted',
            }),
            202,
          );
        }
        fail('Unexpected request: ${request.method} $path');
      });
      final room = RoomSessionController(
        config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
        httpClient: client,
        socketConnector: (_) =>
            throw StateError('socket unavailable in HTTP test'),
      );
      addTearDown(room.dispose);

      await room.create('Signer');
      expect(room.credentials?.code, 'ABCDEFGH');
      expect(room.nextClientSequence, 0);

      await room.sendText('Hello from speech', source: 'speech');
      expect(room.nextClientSequence, 1);

      final fixture = jsonDecode(
        File('../tests/fixtures/translated_sign_utterance_v1.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      fixture['message_id'] = '22222222-2222-4222-8222-222222222222';
      fixture['client_sequence'] = 1;
      final acknowledgement = await room.submit(
        TranslatedSignUtterance.fromJson(fixture),
      );

      expect(acknowledgement.clientSequence, 1);
      expect(room.nextClientSequence, 2);
      expect(requests.map((request) => request.url.path), <String>[
        '/v1/rooms',
        '/v1/rooms/ABCDEFGH/messages',
        '/v1/rooms/ABCDEFGH/sign-utterances',
      ]);

      final signRequest = room.transportTrace.firstWhere(
        (trace) =>
            trace.direction == RoomTransportDirection.frontendToBackend &&
            trace.label == 'POST /v1/rooms/ABCDEFGH/sign-utterances',
      );
      final signBody = signRequest.payload as Map;
      expect((signBody['body'] as Map)['words'], isNotEmpty);
      expect(jsonEncode(signBody), isNot(contains('landmarks')));

      final createResponse = room.transportTrace.firstWhere(
        (trace) =>
            trace.direction == RoomTransportDirection.backendToFrontend &&
            trace.label == 'POST /v1/rooms · HTTP 201',
      );
      expect(jsonEncode(createResponse.payload), contains('[redacted]'));
      expect(
        jsonEncode(createResponse.payload),
        isNot(contains('participant-secret')),
      );
    },
  );

  test('an expired-room response erases tab-scoped credentials', () async {
    var requestCount = 0;
    final storage = RoomSessionStorage();
    final room = RoomSessionController(
      config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
      storage: storage,
      httpClient: MockClient((request) async {
        requestCount += 1;
        if (requestCount == 1) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'utterance_schema_version': '1.0',
              'code': 'ABCDEFGH',
              'participant_id': '11111111-1111-4111-8111-111111111111',
              'role': 'signer',
              'token': 'participant-secret',
              'join_path': '/?room=ABCDEFGH',
            }),
            201,
          );
        }
        return http.Response(
          jsonEncode(<String, String>{'error': 'room_unavailable'}),
          410,
        );
      }),
      socketConnector: (_) =>
          throw StateError('socket unavailable in HTTP test'),
    );
    addTearDown(room.dispose);

    await room.create('Signer');
    expect(storage.read(), isNotNull);

    await expectLater(
      room.sendText('Too late'),
      throwsA(isA<RoomSessionException>()),
    );

    expect(room.hasRoom, isFalse);
    expect(room.status, RoomConnectionStatus.ended);
    expect(storage.read(), isNull);
  });

  test('a changed sign payload reports a typed pending error and the old request can retry', () async {
    var signAttempts = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/rooms') {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'event_schema_version': '1.0',
            'utterance_schema_version': '1.0',
            'code': 'ABCDEFGH',
            'participant_id': '11111111-1111-4111-8111-111111111111',
            'role': 'signer',
            'token': 'participant-secret',
            'join_path': '/?room=ABCDEFGH',
          }),
          201,
        );
      }
      if (request.url.path.endsWith('/sign-utterances')) {
        signAttempts += 1;
        if (signAttempts == 1) {
          throw http.ClientException('response lost');
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'event_schema_version': '1.0',
            'type': 'utterance_ack',
            'message_id': body['message_id'],
            'client_sequence': body['client_sequence'],
            'server_sequence': 0,
            'disposition': 'accepted',
          }),
          202,
        );
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final room = RoomSessionController(
      config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
      httpClient: client,
      socketConnector: (_) => throw StateError('socket unavailable in test'),
    );
    addTearDown(room.dispose);
    await room.create('Signer');

    final firstJson = jsonDecode(
      File('../tests/fixtures/translated_sign_utterance_v1.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final first = TranslatedSignUtterance.fromJson(firstJson);
    await expectLater(
      room.submit(first),
      throwsA(
        isA<TranslatedSignUtteranceSubmissionException>().having(
          (error) => error.code,
          'code',
          'unreachable',
        ),
      ),
    );
    expect(room.hasPendingRetry, isTrue);

    firstJson['message_id'] = '22222222-2222-4222-8222-222222222222';
    final changed = TranslatedSignUtterance.fromJson(firstJson);
    await expectLater(
      room.submit(changed),
      throwsA(
        isA<TranslatedSignUtteranceSubmissionException>().having(
          (error) => error.code,
          'code',
          'pending_message',
        ),
      ),
    );

    await room.retryPendingSubmission();

    expect(room.hasPendingRetry, isFalse);
    expect(room.nextClientSequence, 1);
    expect(signAttempts, 2);
  });

  test(
    'a rejected sign payload is discarded so a corrected sentence can send',
    () async {
      var signAttempts = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/rooms') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'utterance_schema_version': '1.0',
              'code': 'ABCDEFGH',
              'participant_id': '11111111-1111-4111-8111-111111111111',
              'role': 'signer',
              'token': 'participant-secret',
              'join_path': '/?room=ABCDEFGH',
            }),
            201,
          );
        }
        if (request.url.path.endsWith('/sign-utterances')) {
          signAttempts += 1;
          if (signAttempts == 1) {
            return http.Response(
              jsonEncode(<String, String>{'error': 'invalid_utterance'}),
              422,
            );
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'type': 'utterance_ack',
              'message_id': body['message_id'],
              'client_sequence': body['client_sequence'],
              'server_sequence': 0,
              'disposition': 'accepted',
            }),
            202,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      });
      final room = RoomSessionController(
        config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
        httpClient: client,
        socketConnector: (_) => throw StateError('socket unavailable in test'),
      );
      addTearDown(room.dispose);
      await room.create('Signer');

      final fixture = jsonDecode(
        File('../tests/fixtures/translated_sign_utterance_v1.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      await expectLater(
        room.submit(TranslatedSignUtterance.fromJson(fixture)),
        throwsA(
          isA<TranslatedSignUtteranceSubmissionException>()
              .having((error) => error.code, 'code', 'invalid_utterance')
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      );
      expect(room.hasPendingRetry, isFalse);
      expect(room.nextClientSequence, 0);

      fixture['message_id'] = '22222222-2222-4222-8222-222222222222';
      await room.submit(TranslatedSignUtterance.fromJson(fixture));

      expect(room.hasPendingRetry, isFalse);
      expect(room.nextClientSequence, 1);
      expect(signAttempts, 2);
    },
  );

  test('a stale retry that receives a definitive rejection stops blocking later sends', () async {
    var signAttempts = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/rooms') {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'event_schema_version': '1.0',
            'utterance_schema_version': '1.0',
            'code': 'ABCDEFGH',
            'participant_id': '11111111-1111-4111-8111-111111111111',
            'role': 'signer',
            'token': 'participant-secret',
            'join_path': '/?room=ABCDEFGH',
          }),
          201,
        );
      }
      if (request.url.path.endsWith('/sign-utterances')) {
        signAttempts += 1;
        if (signAttempts == 1) {
          throw http.ClientException('response lost');
        }
        if (signAttempts == 2) {
          return http.Response(
            jsonEncode(<String, String>{'error': 'invalid_utterance'}),
            422,
          );
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'event_schema_version': '1.0',
            'type': 'utterance_ack',
            'message_id': body['message_id'],
            'client_sequence': body['client_sequence'],
            'server_sequence': 0,
            'disposition': 'accepted',
          }),
          202,
        );
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final room = RoomSessionController(
      config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
      httpClient: client,
      socketConnector: (_) => throw StateError('socket unavailable in test'),
    );
    addTearDown(room.dispose);
    await room.create('Signer');

    final fixture = jsonDecode(
      File('../tests/fixtures/translated_sign_utterance_v1.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    await expectLater(
      room.submit(TranslatedSignUtterance.fromJson(fixture)),
      throwsA(isA<TranslatedSignUtteranceSubmissionException>()),
    );
    expect(room.hasPendingRetry, isTrue);

    await expectLater(
      room.retryPendingSubmission(),
      throwsA(
        isA<TranslatedSignUtteranceSubmissionException>().having(
          (error) => error.code,
          'code',
          'invalid_utterance',
        ),
      ),
    );
    expect(room.hasPendingRetry, isFalse);

    fixture['message_id'] = '22222222-2222-4222-8222-222222222222';
    await room.submit(TranslatedSignUtterance.fromJson(fixture));
    expect(room.nextClientSequence, 1);
    expect(signAttempts, 3);
  });

  testWidgets(
    'recovers a terminal sign result when its socket event is missed',
    (tester) async {
      const messageId = '22222222-2222-4222-8222-222222222222';
      var snapshotRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/rooms') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'utterance_schema_version': '1.0',
              'code': 'ABCDEFGH',
              'participant_id': '11111111-1111-4111-8111-111111111111',
              'role': 'signer',
              'token': 'participant-secret',
              'join_path': '/?room=ABCDEFGH',
            }),
            201,
          );
        }
        if (request.url.path.endsWith('/sign-utterances')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'type': 'utterance_ack',
              'message_id': messageId,
              'client_sequence': 0,
              'server_sequence': 0,
              'disposition': 'accepted',
            }),
            202,
          );
        }
        if (request.method == 'GET' &&
            request.url.path == '/v1/rooms/ABCDEFGH') {
          snapshotRequests += 1;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'event_schema_version': '1.0',
              'type': 'snapshot',
              'room_version': 2,
              'state': 'active',
              'context_version': 1,
              'participants': <Map<String, dynamic>>[
                <String, dynamic>{
                  'participant_id': '11111111-1111-4111-8111-111111111111',
                  'role': 'signer',
                  'alias': 'Signer',
                  'online': false,
                },
              ],
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message_id': messageId,
                  'sender_id': '11111111-1111-4111-8111-111111111111',
                  'client_sequence': 0,
                  'server_sequence': 0,
                  'context_version': 0,
                  'source': 'sign',
                  'status': 'accepted',
                  'text': 'I want water.',
                  'translation': <String, dynamic>{
                    'status': 'accepted',
                    'text': 'I want water.',
                    'tts_text': 'I want water.',
                    'confidence': 0.9,
                    'confidence_kind': 'normalized_model_score',
                    'model_version': 'provider-test',
                    'policy_version': 'policy-test',
                  },
                },
              ],
            }),
            200,
          );
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      });
      final room = RoomSessionController(
        config: RoomClientConfig(apiOrigin: Uri.parse('http://127.0.0.1:8000')),
        httpClient: client,
        socketConnector: (_) => throw StateError('socket unavailable in test'),
      );

      await room.create('Signer');
      final fixture = jsonDecode(
        File('../tests/fixtures/translated_sign_utterance_v1.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      fixture['message_id'] = messageId;
      fixture['client_sequence'] = 0;
      await room.submit(TranslatedSignUtterance.fromJson(fixture));

      expect(room.messages, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(snapshotRequests, 1);
      expect(room.messages.single.status, 'accepted');
      expect(room.messages.single.text, 'I want water.');
      expect(room.messages.single.ttsText, 'I want water.');
      room.dispose();
      await tester.pump();
    },
  );
}
