import 'gloss_lattice_websocket_client.dart';

const bool supportsAuthorizationHeaders = false;

Future<GlossLatticeTextChannel> openAuthenticatedChannel(
  Uri uri,
  Map<String, String> headers,
) => throw UnsupportedError(
  'This platform cannot attach an Authorization header to a WebSocket.',
);
