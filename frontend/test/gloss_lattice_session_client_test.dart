import 'dart:async';
import 'dart:convert';

import 'package:apptesting/services/gloss_lattice_session_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/gloss_lattice_session_fixtures.dart';

void main() {
  test('POSTs the exact session request and parses the 201 response', () async {
    late http.Request captured;
    final httpClient = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode(latticeOnlySessionResponseJson()),
        201,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final client = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test/application/'),
      client: httpClient,
    );

    final response = await client.createSession(sessionRequest());

    expect(captured.method, 'POST');
    expect(captured.url, Uri.parse('https://api.example.test/v1/sessions'));
    expect(captured.headers['accept'], 'application/json');
    expect(captured.headers['content-type'], 'application/json');
    expect(jsonDecode(captured.body), sessionRequest().toJson());
    expect(captured.url.toString(), isNot(contains(streamToken)));
    expect(response.sessionId, sessionId);
    expect(response.streamToken, streamToken);
  });

  test('accepts the original frozen response shape', () async {
    final client = GlossLatticeSessionClient(
      baseUri: Uri.parse('http://127.0.0.1:8000'),
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode(frozenSessionResponseJson()), 201),
      ),
    );

    final response = await client.createSession(sessionRequest());

    expect(response.latticeWebsocketPath, latticePath);
    expect(response.targetFps, 30);
  });

  test('reports a non-201 response without exposing its body', () async {
    final client = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      client: MockClient(
        (_) async => http.Response('secret backend diagnostics', 422),
      ),
    );

    await expectLater(
      client.createSession(sessionRequest()),
      throwsA(
        isA<GlossLatticeSessionHttpException>()
            .having((error) => error.code, 'code', 'session_creation_failed')
            .having((error) => error.statusCode, 'statusCode', 422)
            .having(
              (error) => error.toString(),
              'safe message',
              isNot(contains('secret backend diagnostics')),
            ),
      ),
    );
  });

  test('reports malformed and non-UTF-8 success responses', () async {
    final malformed = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      client: MockClient((_) async => http.Response('{', 201)),
    );
    await expectLater(
      malformed.createSession(sessionRequest()),
      throwsA(
        isA<GlossLatticeSessionHttpException>().having(
          (error) => error.code,
          'code',
          'invalid_session_response',
        ),
      ),
    );

    final nonUtf8 = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      client: MockClient((_) async => http.Response.bytes(<int>[0xff], 201)),
    );
    await expectLater(
      nonUtf8.createSession(sessionRequest()),
      throwsA(
        isA<GlossLatticeSessionHttpException>().having(
          (error) => error.code,
          'code',
          'invalid_session_response',
        ),
      ),
    );
  });

  test('rejects an oversized success response before JSON parsing', () async {
    final client = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      client: MockClient(
        (_) async => http.Response.bytes(List<int>.filled(65537, 0x20), 201),
      ),
    );

    await expectLater(
      client.createSession(sessionRequest()),
      throwsA(
        isA<GlossLatticeSessionHttpException>().having(
          (error) => error.code,
          'code',
          'invalid_session_response',
        ),
      ),
    );
  });

  test('turns a silent backend into a bounded timeout error', () async {
    final response = Completer<http.Response>();
    final client = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      client: MockClient((_) => response.future),
      requestTimeout: const Duration(milliseconds: 5),
    );

    await expectLater(
      client.createSession(sessionRequest()),
      throwsA(
        isA<GlossLatticeSessionHttpException>().having(
          (error) => error.code,
          'code',
          'session_creation_timeout',
        ),
      ),
    );
  });

  test('does not close a caller-owned HTTP client', () async {
    final httpClient = _RecordingClient();
    final client = GlossLatticeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      client: httpClient,
    );

    client.close();

    expect(httpClient.wasClosed, isFalse);
    await expectLater(
      client.createSession(sessionRequest()),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects unsafe or non-HTTP base URIs', () {
    for (final uri in <String>[
      '/relative',
      'ws://api.example.test',
      'https://user:password@api.example.test',
      'https://api.example.test?token=secret',
      'https://api.example.test/#fragment',
    ]) {
      expect(
        () => GlossLatticeSessionClient(baseUri: Uri.parse(uri)),
        throwsArgumentError,
        reason: '$uri must fail',
      );
    }
    expect(
      () => GlossLatticeSessionClient(
        baseUri: Uri.parse('https://api.example.test'),
        requestTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}

final class _RecordingClient extends http.BaseClient {
  bool wasClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() {
    wasClosed = true;
  }
}
