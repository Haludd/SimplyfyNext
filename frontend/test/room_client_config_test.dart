import 'package:apptesting/config/room_client_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hosted release can use its same-origin room gateway', () {
    final config = RoomClientConfig.resolve(
      configuredOrigin: 'https://backend.example',
      browserLocation: Uri.parse('https://frontend.example/?room=ABCDEFGH'),
      useSameOriginGateway: true,
    );

    expect(config.apiOrigin, Uri.parse('https://frontend.example'));
    expect(
      config.http('/v1/rooms'),
      Uri.parse('https://frontend.example/v1/rooms'),
    );
    expect(
      config.websocket('/v1/rooms/ABCDEFGH/events'),
      Uri.parse('wss://frontend.example/v1/rooms/ABCDEFGH/events'),
    );
    expect(config.usesSameOriginGateway, isTrue);
  });

  test(
    'local development still connects directly to its configured backend',
    () {
      final config = RoomClientConfig.resolve(
        configuredOrigin: 'http://127.0.0.1:8000',
        browserLocation: Uri.parse('http://localhost:8081/'),
        useSameOriginGateway: false,
      );

      expect(config.apiOrigin, Uri.parse('http://127.0.0.1:8000'));
      expect(
        config.http('/v1/rooms'),
        Uri.parse('http://127.0.0.1:8000/v1/rooms'),
      );
      expect(config.usesSameOriginGateway, isFalse);
    },
  );
}
