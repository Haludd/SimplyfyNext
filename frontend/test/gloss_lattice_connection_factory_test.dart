import 'dart:async';

import 'package:apptesting/contracts/gloss_lattice_session.dart';
import 'package:apptesting/services/gloss_lattice_connection_factory.dart';
import 'package:apptesting/services/gloss_lattice_websocket_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/gloss_lattice_session_fixtures.dart';

void main() {
  test('opens HTTPS as WSS with the bearer token only in a header', () async {
    late Uri openedUri;
    late Map<String, String> openedHeaders;
    final channel = _FakeTextChannel();
    final factory = GlossLatticeConnectionFactory(
      opener: (uri, headers) async {
        openedUri = uri;
        openedHeaders = headers;
        return channel;
      },
      supportsAuthorizationHeaders: true,
    );
    final session = GlossLatticeSessionCreateResponse.fromJson(
      latticeOnlySessionResponseJson(),
    );

    final client = await factory.connect(
      baseUri: Uri.parse('https://api.example.test/application/'),
      session: session,
    );

    expect(openedUri, Uri.parse('wss://api.example.test$latticePath'));
    expect(openedUri.query, isEmpty);
    expect(openedUri.userInfo, isEmpty);
    expect(openedUri.toString(), isNot(contains(streamToken)));
    expect(openedHeaders, <String, String>{
      'Authorization': 'Bearer $streamToken',
    });
    expect(
      () => openedHeaders['Authorization'] = 'changed',
      throwsUnsupportedError,
    );
    expect(client.sessionId, sessionId);
    await client.close();
    expect(channel.wasClosed, isTrue);
  });

  test('opens HTTP development origins as WS', () async {
    late Uri openedUri;
    final factory = GlossLatticeConnectionFactory(
      opener: (uri, _) async {
        openedUri = uri;
        return _FakeTextChannel();
      },
      supportsAuthorizationHeaders: true,
    );
    final session = GlossLatticeSessionCreateResponse.fromJson(
      latticeOnlySessionResponseJson(),
    );

    final client = await factory.connect(
      baseUri: Uri.parse('http://127.0.0.1:8000'),
      session: session,
    );

    expect(openedUri, Uri.parse('ws://127.0.0.1:8000$latticePath'));
    await client.close();
  });

  test('browser mode fails clearly without ever calling the opener', () async {
    var openerCalled = false;
    final factory = GlossLatticeConnectionFactory(
      opener: (_, _) async {
        openerCalled = true;
        return _FakeTextChannel();
      },
      supportsAuthorizationHeaders: false,
    );
    final session = GlossLatticeSessionCreateResponse.fromJson(
      latticeOnlySessionResponseJson(),
    );

    await expectLater(
      factory.connect(
        baseUri: Uri.parse('https://api.example.test'),
        session: session,
      ),
      throwsA(
        isA<GlossLatticeConnectionException>()
            .having(
              (error) => error.code,
              'code',
              'browser_authorization_unavailable',
            )
            .having(
              (error) => error.message,
              'message',
              allOf(contains('ticket'), isNot(contains(streamToken))),
            ),
      ),
    );
    expect(openerCalled, isFalse);
  });

  test('reports opener and readiness failures without leaking token', () async {
    for (final opener in <AuthenticatedGlossLatticeChannelOpener>[
      (_, _) async => throw Exception('dial failed'),
      (_, _) async =>
          _FakeTextChannel(readyError: Exception('handshake failed')),
    ]) {
      final factory = GlossLatticeConnectionFactory(
        opener: opener,
        supportsAuthorizationHeaders: true,
      );
      final session = GlossLatticeSessionCreateResponse.fromJson(
        latticeOnlySessionResponseJson(),
      );

      await expectLater(
        factory.connect(
          baseUri: Uri.parse('https://api.example.test'),
          session: session,
        ),
        throwsA(
          isA<GlossLatticeConnectionException>()
              .having((error) => error.code, 'code', 'connection_failed')
              .having(
                (error) => error.toString(),
                'safe error',
                isNot(contains(streamToken)),
              ),
        ),
      );
    }
  });

  test('turns a silent WebSocket opener into a bounded timeout', () async {
    final pending = Completer<GlossLatticeTextChannel>();
    final factory = GlossLatticeConnectionFactory(
      opener: (_, _) => pending.future,
      supportsAuthorizationHeaders: true,
      connectTimeout: const Duration(milliseconds: 5),
    );
    final session = GlossLatticeSessionCreateResponse.fromJson(
      latticeOnlySessionResponseJson(),
    );

    await expectLater(
      factory.connect(
        baseUri: Uri.parse('https://api.example.test'),
        session: session,
      ),
      throwsA(
        isA<GlossLatticeConnectionException>().having(
          (error) => error.code,
          'code',
          'connection_timeout',
        ),
      ),
    );
  });

  test('rejects unsafe base URIs before opening a socket', () async {
    var openerCalls = 0;
    final factory = GlossLatticeConnectionFactory(
      opener: (_, _) async {
        openerCalls += 1;
        return _FakeTextChannel();
      },
      supportsAuthorizationHeaders: true,
    );
    final session = GlossLatticeSessionCreateResponse.fromJson(
      latticeOnlySessionResponseJson(),
    );

    for (final value in <String>[
      '/relative',
      'wss://api.example.test',
      'https://user:password@api.example.test',
      'https://api.example.test?token=value',
      'https://api.example.test/#fragment',
    ]) {
      await expectLater(
        () => factory.connect(baseUri: Uri.parse(value), session: session),
        throwsArgumentError,
        reason: '$value must fail',
      );
    }
    expect(openerCalls, 0);
    expect(
      () => GlossLatticeConnectionFactory(
        supportsAuthorizationHeaders: true,
        connectTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}

final class _FakeTextChannel implements GlossLatticeTextChannel {
  _FakeTextChannel({this.readyError});

  final Object? readyError;
  bool wasClosed = false;

  @override
  Future<void> get ready {
    final error = readyError;
    return error == null ? Future<void>.value() : Future<void>.error(error);
  }

  @override
  Stream<dynamic> get stream => const Stream<dynamic>.empty();

  @override
  void sendText(String message) {}

  @override
  Future<void> close() async {
    wasClosed = true;
  }
}
