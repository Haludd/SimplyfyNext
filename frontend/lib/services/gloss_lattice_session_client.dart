import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../contracts/gloss_lattice_session.dart';

/// HTTP failure while negotiating a frontend-classified lattice session.
final class GlossLatticeSessionHttpException implements Exception {
  const GlossLatticeSessionHttpException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'GlossLatticeSessionHttpException($code, status: $statusCode): $message';
}

/// Creates the short-lived backend session needed before opening a lattice
/// WebSocket.
///
/// Tests can inject an [http.Client]. Production callers may omit it and let
/// this object own a standard client. The bearer token returned by the backend
/// is never written to a URL or log by this class.
final class GlossLatticeSessionClient {
  GlossLatticeSessionClient({
    required Uri baseUri,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 15),
  }) : baseUri = _validateBaseUri(baseUri),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       requestTimeout = _validateTimeout(requestTimeout, 'requestTimeout');

  static const int _maxResponseBytes = 64 * 1024;

  final Uri baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  bool _closed = false;

  Future<GlossLatticeSessionCreateResponse> createSession(
    GlossLatticeSessionCreateRequest request,
  ) async {
    if (_closed) {
      throw StateError('The GlossLattice session client is closed.');
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
      throw const GlossLatticeSessionHttpException(
        code: 'session_creation_timeout',
        message: 'Backend session creation timed out.',
      );
    }

    if (response.statusCode != 201) {
      throw GlossLatticeSessionHttpException(
        code: 'session_creation_failed',
        statusCode: response.statusCode,
        message: 'Backend did not create a GlossLattice session.',
      );
    }
    if (response.bodyBytes.length > _maxResponseBytes) {
      throw const GlossLatticeSessionHttpException(
        code: 'invalid_session_response',
        message: 'Backend session response exceeded 65536 bytes.',
      );
    }

    String source;
    try {
      source = utf8.decode(response.bodyBytes);
    } on FormatException {
      throw const GlossLatticeSessionHttpException(
        code: 'invalid_session_response',
        message: 'Backend session response was not valid UTF-8.',
      );
    }

    try {
      return GlossLatticeSessionCreateResponse.fromWireJson(source);
    } on Exception catch (error) {
      throw GlossLatticeSessionHttpException(
        code: 'invalid_session_response',
        message: 'Backend returned an invalid session response: $error',
      );
    }
  }

  /// Deletes an authenticated session after the WebSocket has closed.
  ///
  /// A 404/410 is treated as success because the server may already have
  /// erased an ended or expired ephemeral session. The bearer token remains
  /// in memory only and is sent in an HTTP header, never in the URL.
  Future<void> deleteSession(GlossLatticeSessionCreateResponse session) async {
    if (_closed) {
      throw StateError('The GlossLattice session client is closed.');
    }

    late http.Response response;
    try {
      response = await _client
          .delete(
            baseUri.resolve('/v1/sessions/${session.sessionId}'),
            headers: <String, String>{
              'accept': 'application/json',
              'Authorization': '${session.tokenType} ${session.streamToken}',
            },
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const GlossLatticeSessionHttpException(
        code: 'session_delete_timeout',
        message: 'Backend session deletion timed out.',
      );
    }

    if (response.statusCode == 204 ||
        response.statusCode == 404 ||
        response.statusCode == 410) {
      return;
    }
    throw GlossLatticeSessionHttpException(
      code: 'session_delete_failed',
      statusCode: response.statusCode,
      message: 'Backend did not delete the GlossLattice session.',
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      _client.close();
    }
  }
}

Duration _validateTimeout(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}

Uri _validateBaseUri(Uri value) {
  if (!value.isAbsolute ||
      (value.scheme != 'http' && value.scheme != 'https') ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment) {
    throw ArgumentError.value(
      value,
      'baseUri',
      'must be an absolute http(s) origin without credentials, query, or '
          'fragment',
    );
  }
  return value;
}
