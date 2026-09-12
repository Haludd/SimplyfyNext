import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contracts/landmark_stream.dart';

final class LandmarkStreamSessionHttpException implements Exception {
  const LandmarkStreamSessionHttpException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'LandmarkStreamSessionHttpException($code, status: $statusCode): '
      '$message';
}

/// Negotiates the short-lived session used by the server-side recognizer.
final class LandmarkStreamSessionClient {
  LandmarkStreamSessionClient({
    required Uri baseUri,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 15),
  }) : baseUri = _validateBaseUri(baseUri),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       requestTimeout = _validateTimeout(requestTimeout) {
    if (this.baseUri.scheme != 'http' && this.baseUri.scheme != 'https') {
      throw ArgumentError.value(
        baseUri,
        'baseUri',
        'must use http or https for session negotiation',
      );
    }
  }

  static const int _maxResponseBytes = 64 * 1024;

  final Uri baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  bool _closed = false;

  Future<LandmarkStreamSession> createSession(
    LandmarkStreamSessionCreateRequest request,
  ) async {
    if (_closed) {
      throw StateError('The landmark stream session client is closed.');
    }

    late http.Response response;
    try {
      response = await _client
          .post(
            baseUri.resolve('/v1/sessions'),
            headers: const <String, String>{
              'accept': 'application/json',
              'content-type': 'application/json',
            },
            body: request.toWireJson(),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const LandmarkStreamSessionHttpException(
        code: 'session_creation_timeout',
        message: 'Railway session creation timed out.',
      );
    } on Object {
      throw const LandmarkStreamSessionHttpException(
        code: 'session_creation_unavailable',
        message: 'Railway session creation could not be reached.',
      );
    }

    if (response.statusCode != 201) {
      throw LandmarkStreamSessionHttpException(
        code: response.statusCode == 422
            ? 'session_configuration_rejected'
            : response.statusCode == 429
            ? 'session_capacity_limited'
            : 'session_creation_failed',
        statusCode: response.statusCode,
        message: _messageForStatus(response.statusCode),
      );
    }
    if (response.bodyBytes.length > _maxResponseBytes) {
      throw const LandmarkStreamSessionHttpException(
        code: 'invalid_session_response',
        message: 'The session response exceeded 65536 bytes.',
      );
    }

    late Object decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on Object {
      throw const LandmarkStreamSessionHttpException(
        code: 'invalid_session_response',
        message: 'Railway returned invalid session JSON.',
      );
    }
    if (decoded is! Map || decoded.keys.any((Object? key) => key is! String)) {
      throw const LandmarkStreamSessionHttpException(
        code: 'invalid_session_response',
        message: 'Railway returned a session response that is not an object.',
      );
    }
    try {
      return LandmarkStreamSession.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } on Object catch (error) {
      throw LandmarkStreamSessionHttpException(
        code: 'invalid_session_response',
        message: 'Railway returned an invalid session response: $error',
      );
    }
  }

  Future<void> deleteSession(LandmarkStreamSession session) async {
    if (_closed) return;
    late http.Response response;
    try {
      response = await _client
          .delete(
            baseUri.resolve('/v1/sessions/${session.sessionId}'),
            headers: <String, String>{
              'accept': 'application/json',
              'Authorization': 'Bearer ${session.streamToken}',
            },
          )
          .timeout(requestTimeout);
    } on Object {
      throw const LandmarkStreamSessionHttpException(
        code: 'session_delete_failed',
        message: 'Railway session deletion could not be completed.',
      );
    }
    if (response.statusCode != 204 &&
        response.statusCode != 404 &&
        response.statusCode != 410) {
      throw LandmarkStreamSessionHttpException(
        code: 'session_delete_failed',
        statusCode: response.statusCode,
        message: 'Railway did not delete the session.',
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }
}

Uri _validateBaseUri(Uri value) {
  if (!value.isAbsolute ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment) {
    throw ArgumentError.value(
      value,
      'baseUri',
      'must be an absolute origin without credentials, query, or fragment',
    );
  }
  return value;
}

Duration _validateTimeout(Duration value) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, 'requestTimeout', 'must be positive');
  }
  return value;
}

String _messageForStatus(int statusCode) => switch (statusCode) {
  422 => 'Railway rejected the client language or detector configuration.',
  429 => 'Railway is temporarily at session capacity.',
  502 || 503 || 504 => 'Railway is currently unavailable.',
  _ => 'Railway did not create the session (HTTP $statusCode).',
};
