import 'dart:convert';
import 'dart:io';

import 'package:apptesting/config/room_client_config.dart';
import 'package:apptesting/contracts/translated_sign_utterance.dart';
import 'package:apptesting/models/room_models.dart';
import 'package:apptesting/services/room_session_controller.dart';
import 'package:apptesting/services/room_session_storage.dart';
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
}
