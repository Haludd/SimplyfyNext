import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tracking_models.dart';

class LocalStateService {
  LocalStateService(this._preferences);

  static const _calibratedKey = 'calibrated';
  static const _customSignsKey = 'custom_signs';
  static const _gestureShortcutsKey = 'gesture_shortcuts_v1';
  static const _customSignsBackupType = 'signbridge_personal_sign_backup';
  static const _customSignsBackupSchemaVersion = 1;
  final SharedPreferences _preferences;

  Future<bool> isCalibrated() async =>
      _preferences.getBool(_calibratedKey) ?? false;

  Future<void> setCalibrated(bool value) =>
      _preferences.setBool(_calibratedKey, value);

  Future<List<CustomSign>> loadCustomSigns() async {
    final encoded = _preferences.getString(_customSignsKey);
    if (encoded == null) return <CustomSign>[];
    try {
      final values = jsonDecode(encoded) as List<dynamic>;
      return values
          .map((value) => CustomSign.fromJson(value as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return <CustomSign>[];
    } on TypeError {
      return <CustomSign>[];
    }
  }

  Future<void> saveCustomSigns(List<CustomSign> signs) {
    final encoded = jsonEncode(signs.map((sign) => sign.toJson()).toList());
    return _preferences.setString(_customSignsKey, encoded);
  }

  /// A portable, user-controlled backup. Personal landmark templates remain
  /// entirely local: callers choose where to save the resulting text.
  String exportCustomSignsBackup(List<CustomSign> signs) =>
      jsonEncode(<String, dynamic>{
        'type': _customSignsBackupType,
        'schema_version': _customSignsBackupSchemaVersion,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'custom_signs': signs.map((sign) => sign.toJson()).toList(),
      });

  /// Decodes a portable backup without changing local state.
  List<CustomSign> decodeCustomSignsBackup(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map ||
          decoded['type'] != _customSignsBackupType ||
          decoded['schema_version'] != _customSignsBackupSchemaVersion ||
          decoded['custom_signs'] is! List) {
        throw const FormatException(
          'This is not a compatible personal-sign backup.',
        );
      }
      final signs = (decoded['custom_signs'] as List)
          .whereType<Map>()
          .map((raw) => CustomSign.fromJson(Map<String, dynamic>.from(raw)))
          .where(
            (sign) => sign.label.trim().isNotEmpty && sign.hasEnoughSamples,
          )
          .toList(growable: false);
      if (signs.isEmpty) {
        throw const FormatException(
          'This backup does not contain a complete personal sign.',
        );
      }
      return signs;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException(
        'This is not a compatible personal-sign backup.',
      );
    }
  }

  /// The selected action-sign labels are local accessibility preferences.
  /// They are never included in a room payload or sent to the backend.
  Future<Map<String, String>> loadGestureShortcuts() async {
    final encoded = _preferences.getString(_gestureShortcutsKey);
    if (encoded == null) return <String, String>{};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return <String, String>{};
      return Map<String, String>.unmodifiable(
        decoded.map(
          (key, value) =>
              MapEntry<String, String>(key.toString(), value.toString().trim()),
        )..removeWhere((_, value) => value.isEmpty),
      );
    } on FormatException {
      return <String, String>{};
    } on TypeError {
      return <String, String>{};
    }
  }

  Future<void> saveGestureShortcuts(Map<String, String> shortcuts) =>
      _preferences.setString(_gestureShortcutsKey, jsonEncode(shortcuts));
}
