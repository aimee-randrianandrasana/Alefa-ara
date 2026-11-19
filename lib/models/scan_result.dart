import 'dart:convert';

/// Informations lues dans un QR code Alefa arà.
///
/// Le QR peut aussi contenir le réseau Wi-Fi de l'hôte (`ssid`, `password`)
/// pour rejoindre automatiquement son point d'accès, comme Xender.
class ScanResult {
  final String address;
  final int port;
  final String key;
  final String name;
  final String? ssid;
  final String? password;

  const ScanResult({
    required this.address,
    required this.port,
    required this.key,
    required this.name,
    this.ssid,
    this.password,
  });

  static ScanResult? tryParse(String raw) {
    final uri = Uri.tryParse(raw);
    // `omeo` reste accepté pour les QR codes imprimés par les anciennes versions.
    if (uri == null ||
        (uri.scheme != 'alefaara' && uri.scheme != 'omeo')) {
      return null;
    }
    final host = uri.host;
    final key = uri.queryParameters['k'];
    if (host.isEmpty || key == null || key.isEmpty) return null;

    final query = uri.queryParameters;
    String decode(String? value) {
      if (value == null || value.isEmpty) return '';
      try {
        final padding = '=' * ((4 - value.length % 4) % 4);
        return utf8.decode(base64Url.decode('$value$padding'));
      } catch (_) {
        return value;
      }
    }

    final name = decode(query['n']).isEmpty ? host : decode(query['n']);
    final ssid = decode(query['s']);
    final password = decode(query['w']);

    return ScanResult(
      address: host,
      port: uri.port == 0 ? 4587 : uri.port,
      key: key,
      name: name,
      ssid: ssid.isEmpty ? null : ssid,
      password: password.isEmpty ? null : password,
    );
  }
}
