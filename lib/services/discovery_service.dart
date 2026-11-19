import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/peer.dart';

/// Découverte directe sur le réseau local, sans Avahi / Bonjour / NSD.
///
/// Chaque appareil envoie une petite annonce UDP en broadcast toutes les deux
/// secondes. Tant que l'annonce arrive, l'appareil reste visible. Dès qu'on
/// appuie sur « Actualiser », un ping broadcast force tout le monde à répondre
/// immédiatement. C'est le même principe que les applications de partage
/// type Xender : on parle directement aux appareils du réseau, sans service
/// intermédiaire qui peut disparaître (d'où les anciens « 404 »).
class DiscoveryService {
  static const String magic = 'alefa';
  static const String version = '2';
  static const int broadcastPort = 4588;
  static const Duration announceInterval = Duration(seconds: 2);
  // Assez long pour survivre aux annonces UDP perdues par le Wi-Fi, sans
  // laisser un appareil éteint apparaître comme connecté trop longtemps.
  static const Duration peerTtl = Duration(seconds: 45);
  static const Duration pruneInterval = Duration(seconds: 3);

  final String instanceId = DateTime.now().microsecondsSinceEpoch.toString() +
      Random().nextInt(100000).toString();

  final Map<String, Peer> _peers = <String, Peer>{};
  final StreamController<List<Peer>> _peerController =
      StreamController<List<Peer>>.broadcast();

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  Set<String> _localIps = <String>{};
  List<InternetAddress> _broadcastTargets = <InternetAddress>[];
  String _name = 'appareil';
  String _platform = 'unknown';
  int _port = 4587;

  Stream<List<Peer>> get peers => _peerController.stream;
  List<Peer> get currentPeers => List.unmodifiable(_peers.values);
  bool get isRunning => _socket != null;

  Future<void> start({
    required String name,
    required String platform,
    int port = 4587,
  }) async {
    await stop();

    _name = name;
    _platform = platform;
    _port = port;
    await _refreshLocalNetworks();

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      broadcastPort,
      reuseAddress: true,
      reusePort: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    socket.listen(_onSocketEvent, onError: (_) {});

    _announceTimer =
        Timer.periodic(announceInterval, (_) => _sendAnnouncement());
    _pruneTimer = Timer.periodic(pruneInterval, (_) => _pruneStalePeers());

    // Annonce et ping immédiats pour ne pas attendre le premier timer.
    _sendAnnouncement();
    _ping();
  }

  /// Met à jour les informations annoncées (changement de nom par exemple).
  void updateInfo({String? name, String? platform, int? port}) {
    if (name != null) _name = name;
    if (platform != null) _platform = platform;
    if (port != null) _port = port;
    _sendAnnouncement();
    _ping();
  }

  /// Bouton « Actualiser » : annonce et ping immédiats.
  ///
  /// On ne vide plus la liste ici : les appareils injoignables sont retirés
  /// par l'interface après un test HTTP `/health`, ce qui évite le
  /// clignotement « visible / invisible ».
  Future<void> refresh() async {
    await _refreshLocalNetworks();
    _sendAnnouncement();
    _ping();
  }

  void _sendAnnouncement({InternetAddress? target}) {
    final socket = _socket;
    if (socket == null) return;

    final payload = jsonEncode(<String, Object?>{
      'a': magic,
      'v': version,
      'i': instanceId,
      'n': base64Url.encode(utf8.encode(_name)),
      'p': _platform,
      'port': _port,
    });

    _broadcast(payload, target: target);
  }

  /// Envoie sur le broadcast limité ET sur le broadcast du sous-réseau.
  ///
  /// Certains routeurs/Android ne relayent pas `255.255.255.255` mais
  /// acceptent `192.168.1.255` : envoyer aux deux rend la découverte fiable.
  void _broadcast(String payload, {InternetAddress? target}) {
    final socket = _socket;
    if (socket == null) return;
    final bytes = utf8.encode(payload);
    final targets = <InternetAddress>{
      ?target,
      ..._broadcastTargets,
    };
    for (final address in targets) {
      try {
        socket.send(bytes, address, broadcastPort);
      } catch (_) {
        // Cette interface est peut-être déconnectée : on essaie la suivante.
      }
    }
  }

  void _ping() {
    final socket = _socket;
    if (socket == null) return;
    final payload = jsonEncode(<String, Object?>{
      'a': magic,
      't': 'ping',
      'i': instanceId,
    });
    _broadcast(payload);
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;

    while (true) {
      final datagram = socket.receive();
      if (datagram == null) return;
      _handleDatagram(datagram);
    }
  }

  void _handleDatagram(Datagram datagram) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(datagram.data, allowMalformed: true));
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['a'] != magic) return;

    final senderId = decoded['i'] as String?;
    if (senderId == null || senderId == instanceId) return;

    if (decoded['t'] == 'ping') {
      // Quelqu'un a appuyé sur Actualiser : on répond en direct.
      _sendAnnouncement(target: datagram.address);
      return;
    }
    if (decoded['v'] != version) return;

    final address = datagram.address.address;
    if (address.isEmpty || _localIps.contains(address)) return;

    String name = address;
    final encodedName = decoded['n'] as String?;
    if (encodedName != null) {
      try {
        name = utf8.decode(base64Url.decode(encodedName), allowMalformed: true);
      } catch (_) {}
    }

    final port = decoded['port'] as int? ?? 4587;
    final peer = Peer.discovered(
      name: name.isEmpty ? address : name,
      address: address,
      port: port,
      platform: decoded['p'] as String? ?? 'unknown',
    );

    final previous = _peers[peer.id];
    _peers[peer.id] = peer;

    // On ne redessine que si l'appareil est nouveau ou a changé d'identité :
    // plus de clignotement à chaque annonce.
    if (previous == null ||
        previous.name != peer.name ||
        previous.port != peer.port ||
        previous.platform != peer.platform) {
      _emit();
    }
  }

  void addManual(Peer peer) {
    _peers[peer.id] = peer;
    _emit();
  }

  void remove(String id) {
    _peers.remove(id);
    _emit();
  }

  void _pruneStalePeers() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere(
      (_, peer) => !peer.manual && now.difference(peer.lastSeen) > peerTtl,
    );
    if (_peers.length != before) _emit();
  }

  void _emit() {
    if (!_peerController.isClosed) {
      _peerController.add(List.unmodifiable(_peers.values));
    }
  }

  Future<void> _refreshLocalNetworks() async {
    _localIps = await _readLocalIps();
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final bytes = address.rawAddress;
          if (bytes.length != 4) continue;
          // La grande majorité des réseaux locaux sont en /24.
          targets.add(
            InternetAddress.fromRawAddress(
              Uint8List.fromList(<int>[bytes[0], bytes[1], bytes[2], 255]),
            ),
          );
        }
      }
    } catch (_) {}
    _broadcastTargets = targets.toList(growable: false);
  }

  static Future<Set<String>> _readLocalIps() async {
    final result = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          result.add(address.address);
        }
      }
    } catch (_) {}
    return result;
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;

    final socket = _socket;
    _socket = null;
    try {
      socket?.close();
    } catch (_) {}

    _peers.clear();
    _emit();
  }

  void dispose() {
    unawaited(stop());
    _peerController.close();
  }
}
