import 'dart:io';

class Peer {
  final String id;
  final String name;
  final String address;
  final int port;
  final String platform;
  final bool manual;
  final DateTime lastSeen;

  const Peer({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.platform,
    this.manual = false,
    required this.lastSeen,
  });

  factory Peer.discovered({
    required String name,
    required String address,
    required int port,
    required String platform,
  }) {
    return Peer(
      id: '$address:$port',
      name: name,
      address: address,
      port: port,
      platform: platform,
      lastSeen: DateTime.now(),
    );
  }

  factory Peer.manual({
    required String name,
    required String address,
    int port = 4587,
  }) {
    return Peer(
      id: 'manual-$address:$port',
      name: name.trim().isEmpty ? address : name.trim(),
      address: address.trim(),
      port: port,
      platform: 'unknown',
      manual: true,
      lastSeen: DateTime.now(),
    );
  }

  String get hostForUri {
    final parsed = InternetAddress.tryParse(address);
    if (parsed != null && parsed.type == InternetAddressType.IPv6) {
      return '[$address]';
    }
    return address;
  }

  Uri get baseUri => Uri(scheme: 'http', host: hostForUri, port: port);

  Peer touch() => copyWith(lastSeen: DateTime.now());

  Peer copyWith({
    String? id,
    String? name,
    String? address,
    int? port,
    String? platform,
    bool? manual,
    DateTime? lastSeen,
  }) {
    return Peer(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      manual: manual ?? this.manual,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'port': port,
        'platform': platform,
        'manual': manual,
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory Peer.fromJson(Map<String, dynamic> json) => Peer(
        id: json['id'] as String,
        name: json['name'] as String,
        address: json['address'] as String,
        port: json['port'] as int,
        platform: json['platform'] as String? ?? 'unknown',
        manual: json['manual'] as bool? ?? false,
        lastSeen: DateTime.tryParse(json['lastSeen'] as String? ?? '') ??
            DateTime.now(),
      );
}
