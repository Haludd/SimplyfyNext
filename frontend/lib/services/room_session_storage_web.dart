import 'package:web/web.dart' as web;

final class RoomSessionStorage {
  static const _key = 'signbridge-room-v1';

  String? read() => web.window.sessionStorage.getItem(_key);
  void write(String value) => web.window.sessionStorage.setItem(_key, value);
  void clear() => web.window.sessionStorage.removeItem(_key);
}
