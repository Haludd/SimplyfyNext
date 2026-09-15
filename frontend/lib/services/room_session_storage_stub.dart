final class RoomSessionStorage {
  String? _value;

  String? read() => _value;
  void write(String value) => _value = value;
  void clear() => _value = null;
}
