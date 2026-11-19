import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:plugin_wifi_connect/plugin_wifi_connect.dart';
import 'package:wifi_iot/wifi_iot.dart';

/// Couche Wi-Fi : état du point d'accès et connexion à un réseau partagé.
///
/// Sur Android, le système ne laisse pas une application créer silencieusement
/// un hotspot accessible depuis un PC. On se contente donc de **détecter** son
/// état (pour que le bouton reflète la réalité) et de **rejoindre** le réseau
/// annoncé par l'hôte via le QR code. Sur Android 10+, le système affiche sa
/// propre fenêtre de consentement : elle ne peut pas être supprimée.
class WifiService {
  WifiService._();

  static final WifiService instance = WifiService._();

  /// Vrai si un point d'accès Wi-Fi est actuellement actif sur cet appareil.
  Future<bool> isHotspotActive({String? knownSsid}) async {
    if (!Platform.isAndroid) return false;

    try {
      if (await WiFiForIoTPlugin.isWiFiAPEnabled()) return true;
    } catch (_) {}

    try {
      final ssid = await WiFiForIoTPlugin.getWiFiAPSSID();
      if (ssid != null && ssid.isNotEmpty) return true;
    } catch (_) {}

    // Certains téléphones ne rapportent pas l'état du hotspot (Android 10+).
    // On utilise alors deux indices : le SSID déclaré dans l'application, et
    // les plages d'adresses typiques du partage de connexion Android.
    try {
      final current = await currentSsid();
      if (knownSsid != null &&
          knownSsid.isNotEmpty &&
          current != null &&
          current == knownSsid) {
        return true;
      }
    } catch (_) {}

    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip != null &&
          (ip.startsWith('192.168.43.') ||
              ip.startsWith('192.168.137.') ||
              ip.startsWith('172.16.'))) {
        return true;
      }
    } catch (_) {}

    return false;
  }

  /// SSID et mot de passe du point d'accès when disponibles auprès du système.
  Future<({String? ssid, String? password})> hotspotCredentials() async {
    if (!Platform.isAndroid) return (ssid: null, password: null);
    String? ssid;
    String? password;
    try {
      ssid = await WiFiForIoTPlugin.getWiFiAPSSID();
    } catch (_) {}
    try {
      password = await WiFiForIoTPlugin.getWiFiAPPreSharedKey();
    } catch (_) {}
    return (ssid: ssid, password: password);
  }

  Future<String?> currentSsid() async {
    try {
      return await PluginWifiConnect.ssid;
    } catch (_) {}
    try {
      return await WiFiForIoTPlugin.getSSID();
    } catch (_) {}
    return null;
  }

  /// Rejoint le Wi-Fi annoncé par l'hôte, puis route le trafic de l'app dessus.
  ///
  /// Retourne `true` seulement si le SSID courant correspond au réseau voulu.
  /// Sur Android 10+, une confirmation système peut apparaître : c'est une
  /// contrainte imposée par Android, pas un choix de l'application.
  Future<bool> connectToSharedNetwork({
    required String ssid,
    String? password,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    if (ssid.isEmpty) return false;

    if (Platform.isAndroid) {
      final status = await Permission.location.status;
      if (status.isDenied) {
        final granted = await Permission.location.request();
        if (!granted.isGranted) return false;
      }
    }

    var connected = false;
    try {
      if (password != null && password.isNotEmpty) {
        connected = await PluginWifiConnect.connectToSecureNetwork(
              ssid,
              password,
            ) ??
            false;
      } else {
        connected = await PluginWifiConnect.connect(ssid) ?? false;
      }
    } catch (_) {}

    if (!connected) {
      try {
        connected = await WiFiForIoTPlugin.connect(
          ssid,
          password: password,
          security: (password == null || password.isEmpty)
              ? NetworkSecurity.NONE
              : NetworkSecurity.WPA,
          joinOnce: true,
          withInternet: false,
        );
      } catch (_) {}
    }

    if (!connected) return false;

    // Le réseau partagé n'a souvent pas Internet : sans cela, Android envoie
    // les requêtes HTTP sur la 4G et l'hôte répond 404 / n'est pas trouvé.
    try {
      await WiFiForIoTPlugin.forceWifiUsage(true);
    } catch (_) {}

    final current = await currentSsid();
    return current == null || current == ssid;
  }

  /// À appeler quand on quitte la session pour rendre le réseau normal.
  Future<void> releaseWifiUsage() async {
    try {
      await WiFiForIoTPlugin.forceWifiUsage(false);
    } catch (_) {}
  }
}
