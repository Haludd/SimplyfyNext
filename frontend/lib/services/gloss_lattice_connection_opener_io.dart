import 'package:web_socket_channel/io.dart';

import 'gloss_lattice_websocket_client.dart';

const bool supportsAuthorizationHeaders = true;

Future<GlossLatticeTextChannel> openAuthenticatedChannel(
  Uri uri,
  Map<String, String> headers,
) async => WebSocketGlossLatticeTextChannel(
  IOWebSocketChannel.connect(uri, headers: headers),
);
