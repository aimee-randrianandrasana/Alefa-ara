import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/transfer.dart';

class StorageService {
  static const _deviceNameKey = 'device_name';
  static const _historyKey = 'transfer_history';
  static const _wifiSsidKey = 'shared_wifi_ssid';
  static const _wifiPasswordKey = 'shared_wifi_password';
  static const _maxHistory = 100;

  final SharedPreferences _prefs;

  StorageService(this._prefs);

  static Future<StorageService> create() async {
    return StorageService(await SharedPreferences.getInstance());
  }

  String? get deviceName => _prefs.getString(_deviceNameKey);

  Future<void> setDeviceName(String name) =>
      _prefs.setString(_deviceNameKey, name.trim());

  /// Réseau Wi-Fi que cet appareil partage avec les autres (mode Xender).
  String? get sharedWifiSsid => _prefs.getString(_wifiSsidKey);

  String? get sharedWifiPassword => _prefs.getString(_wifiPasswordKey);

  Future<void> setSharedWifi(String ssid, String password) async {
    await _prefs.setString(_wifiSsidKey, ssid.trim());
    await _prefs.setString(_wifiPasswordKey, password);
  }

  Future<void> clearSharedWifi() async {
    await _prefs.remove(_wifiSsidKey);
    await _prefs.remove(_wifiPasswordKey);
  }

  List<Transfer> get history {
    final raw = _prefs.getStringList(_historyKey) ?? const <String>[];
    final result = <Transfer>[];
    for (final item in raw) {
      try {
        result.add(Transfer.fromJson(jsonDecode(item) as Map<String, dynamic>));
      } catch (_) {
        // Ignore corrupted entries.
      }
    }
    return result;
  }

  Future<void> addHistory(Transfer transfer) async {
    final items = history.map((t) => jsonEncode(t.toJson())).toList()
      ..insert(0, jsonEncode(transfer.toJson()));
    await _prefs.setStringList(
      _historyKey,
      items.take(_maxHistory).toList(growable: false),
    );
  }

  Future<void> clearHistory() => _prefs.remove(_historyKey);
}
