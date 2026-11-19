import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/join_request.dart';
import '../models/peer.dart';

class IncomingTransfer {
  final String id;
  final String fileName;
  final int size;
  final String fromAddress;
  final Completer<bool> decision = Completer<bool>();
  final StreamController<double> progress = StreamController<double>.broadcast();

  IncomingTransfer({
    required this.id,
    required this.fileName,
    required this.size,
    required this.fromAddress,
  });

  bool get accepted => decision.isCompleted;

  void accept() {
    if (!decision.isCompleted) {
      decision.complete(true);
      progress.add(0.0);
    }
  }

  void refuse() {
    if (!decision.isCompleted) decision.complete(false);
  }

  void dispose() {
    if (!progress.isClosed) progress.close();
  }
}

/// Serveur local + gestion de la session sécurisée.
///
/// Tant qu'aucune session n'est active, aucun fichier n'est accepté.
/// La clé générée par l'hôte doit accompagner chaque requête de transfert.
class TransferServer {
  String deviceName;
  final String platform;
  final String saveDirectory;
  final void Function(String path, String name, int size)? onFileSaved;

  /// IP locale de cet appareil, renseignée par l'interface au démarrage.
  String localAddress = '127.0.0.1';

  /// Identifiant de version du protocole : les anciennes versions qui
  /// répondaient 404 sont détectées avant toute tentative de connexion.
  static const int protocolVersion = 3;

  HttpServer? _server;
  String? _sessionKey;
  bool _isHost = false;
  final List<Peer> _sessionPeers = <Peer>[];

  final StreamController<IncomingTransfer> _incoming =
      StreamController<IncomingTransfer>.broadcast();
  final StreamController<JoinRequest> _joinRequests =
      StreamController<JoinRequest>.broadcast();
  final StreamController<List<Peer>> _sessionPeersController =
      StreamController<List<Peer>>.broadcast();

  TransferServer({
    required this.deviceName,
    required this.platform,
    required this.saveDirectory,
    this.onFileSaved,
  });

  Stream<IncomingTransfer> get incoming => _incoming.stream;
  Stream<JoinRequest> get joinRequests => _joinRequests.stream;
  Stream<List<Peer>> get sessionPeers => _sessionPeersController.stream;

  int? get port => _server?.port;
  String? get sessionKey => _sessionKey;
  bool get isHost => _isHost;
  bool get isSessionActive => _sessionKey != null;
  List<Peer> get connectedPeers => List.unmodifiable(_sessionPeers);

  /// Crée une session et renvoie la clé à 6 chiffres.
  String startSession() {
    final random = Random.secure();
    _sessionKey = List.generate(6, (_) => random.nextInt(10)).join();
    _isHost = true;
    _sessionPeers.clear();
    _emitPeers();
    return _sessionKey!;
  }

  /// Rejoint une session existante avec la clé de l'hôte.
  void joinSession({required String key, required Peer host}) {
    _sessionKey = key;
    _isHost = false;
    _sessionPeers
      ..clear()
      ..add(host);
    _emitPeers();
  }

  /// Reçoit la liste des appareils connectés (poussée par l'hôte).
  void setPeers(List<Peer> peers) {
    if (_sessionKey == null) return;
    _sessionPeers
      ..clear()
      ..addAll(peers.where((peer) => peer.address != localAddress));
    _emitPeers();
  }

  void leaveSession() {
    _sessionKey = null;
    _isHost = false;
    _sessionPeers.clear();
    _emitPeers();
  }

  Future<int> start({int port = 4587}) async {
    final handler = Pipeline().addHandler(_handle);
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void dispose() {
    _incoming.close();
    _joinRequests.close();
    _sessionPeersController.close();
  }

  void _emitPeers() {
    if (!_sessionPeersController.isClosed) {
      _sessionPeersController.add(List.unmodifiable(_sessionPeers));
    }
  }

  Future<Response> _handle(Request request) async {
    final path = request.url.path;

    if (path == '/api/info' && request.method == 'GET') {
      return _json({
        'name': deviceName,
        'platform': platform,
        'version': protocolVersion,
        'port': port,
        'sessionActive': isSessionActive,
        'joinPath': '/api/session/join',
      });
    }

    if (path == '/health' && request.method == 'GET') {
      return Response.ok('ok');
    }

    if (path == '/api/session/host' && request.method == 'POST') {
      return _json({'key': startSession()});
    }

    if (path == '/api/session/join' && request.method == 'POST') {
      return _join(request);
    }

    if (path == '/api/session/peers' && request.method == 'POST') {
      return _updatePeers(request);
    }

    if (path == '/api/session/status' && request.method == 'GET') {
      return _json({
        'active': isSessionActive,
        'host': _isHost,
        'peerCount': _sessionPeers.length,
      });
    }

    if (path == '/api/transfer' && request.method == 'POST') {
      return _receive(request);
    }

    return Response.notFound('Not found');
  }

  Future<Response> _join(Request request) async {
    if (_sessionKey == null || !_isHost) {
      return Response.forbidden('Cet appareil n\'est pas un hôte de session');
    }

    final query = request.url.queryParameters;
    if (query['key'] != _sessionKey) {
      return Response.forbidden('Clé de session incorrecte');
    }

    final connectionInfo =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;

    final name = query['name'] ?? 'Appareil';
    // L'adresse annoncée par le client peut être fausse (Wi-Fi + Ethernet,
    // hotspot, VPN...). On utilise celle que le serveur a réellement vue.
    final address = connectionInfo?.remoteAddress.address ?? query['address'] ?? '';
    // De même, l'IP de l'hôte doit être celle par laquelle le client est
    // arrivé, pas une autre interface réseau de la machine.
    final hostAddress =
        await _addressSeenByPeer(address, fallback: localAddress);
    final peerPort = int.tryParse(query['port'] ?? '') ?? 4587;
    if (address.isEmpty) return Response.badRequest();

    final joinRequest = JoinRequest(
      name: name,
      address: address,
      port: peerPort,
      receivedAt: DateTime.now(),
    );
    if (!_joinRequests.isClosed) _joinRequests.add(joinRequest);

    bool accepted;
    try {
      accepted = await joinRequest.decision.future
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      accepted = false;
    }
    if (!accepted) return Response.forbidden('Connexion refusée par l\'hôte');

    final peer = Peer.manual(name: name, address: address, port: peerPort);
    if (!_sessionPeers.any((item) => item.id == peer.id)) {
      _sessionPeers.add(peer);
      _emitPeers();
    }

    final allPeers = <Peer>[
      Peer.manual(
        name: deviceName,
        address: hostAddress,
        port: port ?? 4587,
      ),
      ..._sessionPeers,
    ];

    return _json({'key': _sessionKey, 'peers': _peersToJson(allPeers)});
  }

  Future<Response> _updatePeers(Request request) async {
    final query = request.url.queryParameters;
    if (_sessionKey == null || query['key'] != _sessionKey) {
      return Response.forbidden('Session invalide');
    }

    try {
      final body = await request.readAsString();
      final decoded = jsonDecode(body) as List<dynamic>;
      final peers = decoded
          .whereType<Map<String, dynamic>>()
          .map(Peer.fromJson)
          .toList();
      setPeers(peers);
      return Response.ok('ok');
    } catch (_) {
      return Response.badRequest();
    }
  }

  Future<Response> _receive(Request request) async {
    final query = request.url.queryParameters;
    if (_sessionKey == null || query['key'] != _sessionKey) {
      return Response.forbidden('Aucune session autorisée');
    }

    final fileName = _safeName(query['name'] ?? 'file');
    final size = int.tryParse(query['size'] ?? '0') ?? 0;
    final id = query['id'] ?? DateTime.now().microsecondsSinceEpoch.toString();

    final connectionInfo =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final fromAddress = connectionInfo?.remoteAddress.address ?? 'inconnu';

    final incoming = IncomingTransfer(
      id: id,
      fileName: fileName,
      size: size,
      fromAddress: fromAddress,
    );
    if (!_incoming.isClosed) _incoming.add(incoming);

    bool accepted;
    try {
      accepted = await incoming.decision.future
          .timeout(const Duration(seconds: 120));
    } on TimeoutException {
      accepted = false;
    }

    if (!accepted) {
      incoming.dispose();
      return Response.forbidden('Transfert refusé');
    }

    final directory = Directory(saveDirectory);
    if (!directory.existsSync()) await directory.create(recursive: true);

    var target = p.join(directory.path, fileName);
    var counter = 1;
    while (File(target).existsSync()) {
      final ext = p.extension(fileName);
      final stem = p.basenameWithoutExtension(fileName);
      target = p.join(directory.path, '$stem ($counter)$ext');
      counter++;
    }

    final sink = File(target).openWrite();
    var received = 0;
    try {
      await for (final chunk in request.read()) {
        sink.add(chunk);
        received += chunk.length;
        if (!incoming.progress.isClosed) {
          incoming.progress.add(size > 0 ? received / size : 0.0);
        }
      }
    } finally {
      await sink.close();
      if (!incoming.progress.isClosed) incoming.progress.add(1.0);
      onFileSaved?.call(target, p.basename(target), received);
      incoming.dispose();
    }

    return _json({'saved': p.basename(target), 'received': received});
  }

  /// Choisit l'IP locale qui est dans le même sous-réseau que le client.
  /// C'est celle que le client doit utiliser pour nous rejoindre : évite les
  /// 404 quand la machine a plusieurs interfaces (Wi-Fi, Ethernet, hotspot).
  static Future<String> _addressSeenByPeer(
    String remote, {
    required String fallback,
  }) async {
    try {
      final parts = remote.split('.');
      if (parts.length != 4) return fallback;
      final prefix = parts.take(3).join('.');
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.address.startsWith('$prefix.')) return address.address;
        }
      }
    } catch (_) {}
    return fallback;
  }

  static Response _json(Object body) => Response.ok(
        jsonEncode(body),
        headers: const {'content-type': 'application/json'},
      );

  static List<Map<String, dynamic>> _peersToJson(List<Peer> peers) =>
      peers.map((peer) => peer.toJson()).toList();

  static String _safeName(String raw) {
    var name = p.basename(raw.replaceAll(r'\', '/'));
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._()\- ]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') return 'file';
    return name;
  }
}
