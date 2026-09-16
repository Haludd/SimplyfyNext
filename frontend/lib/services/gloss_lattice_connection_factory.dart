import 'dart:async';

import '../contracts/gloss_lattice_session.dart';
import 'gloss_lattice_connection_opener_stub.dart'
    if (dart.library.io) 'gloss_lattice_connection_opener_io.dart'
    as platform;
import 'gloss_lattice_websocket_client.dart';

typedef AuthenticatedGlossLatticeChannelOpener =
    Future<GlossLatticeTextChannel> Function(
      Uri uri,
      Map<String, String> headers,
    );

/// Failure while converting a negotiated session into an authenticated
/// lattice WebSocket connection.
final class GlossLatticeConnectionException implements Exception {
  const GlossLatticeConnectionException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'GlossLatticeConnectionException($code): $message';
}

/// Opens the exact WebSocket path returned by session negotiation.
///
/// Native Dart/Flutter can attach the short-lived bearer token as an
/// `Authorization` header. A standard browser WebSocket cannot. On web this
/// factory therefore fails explicitly until the backend supplies a secure
/// short-lived ticket, cookie, or equivalent handshake. It never puts the
/// bearer token in a URL query parameter.
final class GlossLatticeConnectionFactory {
  GlossLatticeConnectionFactory({
    AuthenticatedGlossLatticeChannelOpener? opener,
    bool? supportsAuthorizationHeaders,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration responseTimeout = const Duration(seconds: 60),
    this.websocketBaseUri,
    this.onEvent,
  }) : _opener = opener ?? platform.openAuthenticatedChannel,
       _supportsAuthorizationHeaders =
           supportsAuthorizationHeaders ??
           platform.supportsAuthorizationHeaders,
       _connectTimeout = _validateTimeout(connectTimeout),
       _responseTimeout = _validateTimeout(responseTimeout);

  final AuthenticatedGlossLatticeChannelOpener _opener;
  final bool _supportsAuthorizationHeaders;
  final Duration _connectTimeout;
  final Duration _responseTimeout;
  final Uri? websocketBaseUri;
  final void Function(Map<String, dynamic> event)? onEvent;

  Future<GlossLatticeWebSocketClient> connect({
    required Uri baseUri,
    required GlossLatticeSessionCreateResponse session,
  }) async {
    if (baseUri.scheme != 'http' && baseUri.scheme != 'https') {
      throw ArgumentError.value(
        baseUri,
        'baseUri',
        'must be an absolute http(s) origin',
      );
    }
    final websocketUri = _websocketUri(
      websocketBaseUri ?? baseUri,
      session.websocketPath,
    );
    if (!_supportsAuthorizationHeaders) {
      throw const GlossLatticeConnectionException(
        code: 'browser_authorization_unavailable',
        message:
            'Browser WebSockets cannot attach the required Authorization '
            'header. The backend must first provide a secure short-lived '
            'WebSocket ticket or equivalent handshake.',
      );
    }

    // Deliberately create the credential only after the URL is final. The
    // token is supplied to the channel opener solely as a request header.
    final headers = Map<String, String>.unmodifiable(<String, String>{
      'Authorization': '${session.tokenType} ${session.streamToken}',
    });
    if (websocketUri.toString().contains(session.streamToken)) {
      throw const GlossLatticeConnectionException(
        code: 'unsafe_websocket_uri',
        message: 'The bearer token must never appear in the WebSocket URL.',
      );
    }

    GlossLatticeTextChannel? channel;
    try {
      channel = await _opener(websocketUri, headers).timeout(_connectTimeout);
      await channel.ready.timeout(_connectTimeout);
    } on TimeoutException {
      if (channel != null) {
        try {
          await channel.close();
        } on Object {
          // Preserve the useful timeout error.
        }
      }
      throw const GlossLatticeConnectionException(
        code: 'connection_timeout',
        message: 'The authenticated GlossLattice WebSocket timed out.',
      );
    } on GlossLatticeConnectionException {
      rethrow;
    } on Object {
      if (channel != null) {
        try {
          await channel.close();
        } on Object {
          // The original connection failure is the useful public result.
        }
      }
      throw const GlossLatticeConnectionException(
        code: 'connection_failed',
        message: 'The authenticated GlossLattice WebSocket could not open.',
      );
    }

    return GlossLatticeWebSocketClient(
      channel: channel,
      sessionId: session.sessionId,
      responseTimeout: _responseTimeout,
      onEvent: onEvent,
    );
  }
}

Duration _validateTimeout(Duration value) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(
      value,
      'connectTimeout',
      'must be greater than zero',
    );
  }
  return value;
}

Uri _websocketUri(Uri baseUri, String websocketPath) {
  if (!baseUri.isAbsolute ||
      (baseUri.scheme != 'http' &&
          baseUri.scheme != 'https' &&
          baseUri.scheme != 'ws' &&
          baseUri.scheme != 'wss') ||
      baseUri.host.isEmpty ||
      baseUri.userInfo.isNotEmpty ||
      baseUri.hasQuery ||
      baseUri.hasFragment) {
    throw ArgumentError.value(
      baseUri,
      'baseUri',
      'must be an absolute http(s) origin without credentials, query, or '
          'fragment',
    );
  }

  final path = Uri.tryParse(websocketPath);
  if (path == null ||
      path.hasScheme ||
      path.hasAuthority ||
      path.hasQuery ||
      path.hasFragment ||
      !websocketPath.startsWith('/')) {
    throw const GlossLatticeConnectionException(
      code: 'invalid_websocket_path',
      message: 'The negotiated WebSocket path must be a relative path.',
    );
  }

  final resolved = baseUri.resolveUri(path);
  final websocketScheme = switch (baseUri.scheme) {
    'https' || 'wss' => 'wss',
    _ => 'ws',
  };
  return resolved.replace(scheme: websocketScheme);
}
