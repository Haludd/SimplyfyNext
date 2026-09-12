import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tracking_models.dart';

class LocalStateService {
  LocalStateService(this._preferences);

  static const _calibratedKey = 'calibrated';
  static const _customSignsKey = 'custom_signs';
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
}
