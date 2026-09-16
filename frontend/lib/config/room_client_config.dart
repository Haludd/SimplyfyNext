import 'package:flutter/foundation.dart';

/// Public, non-secret location of the SimplyNext room API.
final class RoomClientConfig {
  RoomClientConfig({required this.apiOrigin}) {
    if (!apiOrigin.isAbsolute || apiOrigin.host.isEmpty) {
      throw ArgumentError.value(apiOrigin, 'apiOrigin', 'must be absolute');
    }
    if (apiOrigin.path.isNotEmpty && apiOrigin.path != '/') {
      throw ArgumentError.value(
        apiOrigin,
        'apiOrigin',
        'must contain only the public origin, without an API path',
      );
    }
    if (apiOrigin.scheme != 'https' &&
        !(apiOrigin.scheme == 'http' && _isLoopback(apiOrigin.host))) {
      throw ArgumentError.value(
        apiOrigin,
        'apiOrigin',
        'must use HTTPS outside loopback development',
      );
    }
  }

  factory RoomClientConfig.fromEnvironment() {
    const configured = String.fromEnvironment('SIGNBRIDGE_API_BASE_URL');
    final value = configured.trim().isEmpty
        ? 'http://127.0.0.1:8000'
        : configured.trim();
    return RoomClientConfig(apiOrigin: Uri.parse(value));
  }

  final Uri apiOrigin;

  Uri http(String path) =>
      apiOrigin.replace(path: path, query: null, fragment: null);

  Uri websocket(String path) =>
      http(path).replace(scheme: apiOrigin.scheme == 'https' ? 'wss' : 'ws');

  bool get isLocal => _isLoopback(apiOrigin.host);

  String get displayOrigin => apiOrigin.origin;
}

bool _isLoopback(String host) {
  final value = host.toLowerCase();
  return value == 'localhost' || value == '127.0.0.1' || value == '::1';
}

@visibleForTesting
bool isLoopbackRoomHost(String host) => _isLoopback(host);
