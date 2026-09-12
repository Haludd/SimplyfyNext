import 'dart:async';

import 'gloss_lattice_websocket_client.dart';
import 'gloss_lattice_connection_opener_stub.dart'
    if (dart.library.io) 'gloss_lattice_connection_opener_io.dart'
    as platform;

typedef AuthenticatedLandmarkChannelOpener =
    Future<GlossLatticeTextChannel> Function(
      Uri uri,
      Map<String, String> headers,
    );

/// Opens the protected landmark-ingestion socket used by the server-side
/// normaliser, segmenter, and classifier.
final class LandmarkStreamConnectionFactory {
  LandmarkStreamConnectionFactory({
    AuthenticatedLandmarkChannelOpener? opener,
    bool? supportsAuthorizationHeaders,
    Duration connectTimeout = const Duration(seconds: 15),
  }) : _opener = opener ?? platform.openAuthenticatedChannel,
       _supportsAuthorizationHeaders =
           supportsAuthorizationHeaders ?? platform.supportsAuthorizationHeaders,
       _connectTimeout = _validateTimeout(connectTimeout);

  final AuthenticatedLandmarkChannelOpener _opener;
  final bool _supportsAuthorizationHeaders;
  final Duration _connectTimeout;

  Future<GlossLatticeTextChannel> connect({
    required Uri websocketBaseUri,
    required String websocketPath,
    required String streamToken,
  }) async {
    if (!_supportsAuthorizationHeaders) {
      throw const LandmarkStreamConnectionException(
        code: 'browser_authorization_unavailable',
        message:
            'Browser WebSockets cannot attach the required Authorization '
            'header. The backend needs a secure browser ticket or cookie.',
      );
    }
    final uri = _websocketUri(websocketBaseUri, websocketPath);
    if (streamToken.isEmpty || uri.toString().contains(streamToken)) {
      throw const LandmarkStreamConnectionException(
        code: 'unsafe_websocket_uri',
        message: 'The bearer token must never appear in the WebSocket URL.',
      );
    }

    GlossLatticeTextChannel? channel;
    try {
      channel = await _opener(
        uri,
        <String, String>{'Authorization': 'Bearer $streamToken'},
      ).timeout(_connectTimeout);
      await channel.ready.timeout(_connectTimeout);
      return channel;
    } on TimeoutException {
      await _closeQuietly(channel);
      throw const LandmarkStreamConnectionException(
        code: 'connection_timeout',
        message: 'The authenticated landmark WebSocket timed out.',
      );
    } on LandmarkStreamConnectionException {
      rethrow;
    } on Object {
      await _closeQuietly(channel);
      throw const LandmarkStreamConnectionException(
        code: 'connection_failed',
        message: 'The authenticated landmark WebSocket could not open.',
      );
    }
  }
}

final class LandmarkStreamConnectionException implements Exception {
  const LandmarkStreamConnectionException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'LandmarkStreamConnectionException($code): $message';
}

Future<void> _closeQuietly(GlossLatticeTextChannel? channel) async {
  if (channel == null) return;
  try {
    await channel.close();
  } on Object {
    // Preserve the original connection failure.
  }
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
      'websocketBaseUri',
      'must be an absolute origin without credentials, query, or fragment',
    );
  }
  final path = Uri.tryParse(websocketPath);
  if (path == null ||
      path.hasScheme ||
      path.hasAuthority ||
      path.hasQuery ||
      path.hasFragment ||
      !websocketPath.startsWith('/')) {
    throw const LandmarkStreamConnectionException(
      code: 'invalid_websocket_path',
      message: 'The negotiated WebSocket path must be an absolute path.',
    );
  }
  final resolved = baseUri.resolveUri(path);
  return resolved.replace(
    scheme: baseUri.scheme == 'https' || baseUri.scheme == 'wss' ? 'wss' : 'ws',
  );
}

Duration _validateTimeout(Duration value) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, 'connectTimeout', 'must be positive');
  }
  return value;
}
