import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/peer.dart';

class SendResult {
  final bool ok;
  final String? error;
  final String? savedName;

  const SendResult._({required this.ok, this.error, this.savedName});

  factory SendResult.success(String savedName) =>
      SendResult._(ok: true, savedName: savedName);
  factory SendResult.failure(String error) =>
      SendResult._(ok: false, error: error);
}

/// Résultat de la vérification d'un hôte avant de tenter de le rejoindre.
class HostProbe {
  final bool reachable;
  final int? version;
  final String? name;
  final String? error;

  const HostProbe._({
    required this.reachable,
    this.version,
    this.name,
    this.error,
  });

  factory HostProbe.ok({required int version, String? name}) => HostProbe._(
        reachable: true,
        version: version,
        name: name,
      );

  factory HostProbe.failure(String error) =>
      HostProbe._(reachable: false, error: error);
}

class JoinResult {
  final List<Peer> peers;
  final String? error;

  const JoinResult._({required this.peers, this.error});

  factory JoinResult.success(List<Peer> peers) => JoinResult._(peers: peers);
  factory JoinResult.failure(String error) =>
      JoinResult._(peers: const <Peer>[], error: error);

  bool get ok => error == null;
}

class TransferClient {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// Vérifie qu'un appareil répond bien avant d'essayer de l'utiliser.
  /// Évite les erreurs 404 dues à une adresse IP périmée.
  Future<bool> isReachable(Peer peer) async {
    try {
      final request = await _client
          .getUrl(peer.baseUri.resolve('/health'))
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Vérifie que l'adresse pointe bien vers une version compatible d'Alefa arà.
  ///
  /// Un 404 ici signifie presque toujours qu'on parle à une ancienne version
  /// de l'application (ou à un autre serveur) : on le traduit en message clair.
  Future<HostProbe> probeHost(Peer peer) async {
    final uri = peer.baseUri.resolve('/api/info');
    try {
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 404) {
        return HostProbe.failure(
          'Cet appareil ne répond pas comme Alefa arà (404). '
          'Installez la version actuelle sur les deux appareils.',
        );
      }
      if (response.statusCode != 200) {
        return HostProbe.failure('HTTP ${response.statusCode}: $body');
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final version = decoded['version'] as int?;
      if (version == null || decoded['joinPath'] != '/api/session/join') {
        return HostProbe.failure(
          'Version de l\'application incompatible. Mettez les deux '
          'appareils à jour.',
        );
      }
      return HostProbe.ok(
        version: version,
        name: decoded['name'] as String?,
      );
    } catch (error) {
      return HostProbe.failure(
        'Hôte injoignable à ${peer.address}:${peer.port}. '
        'Vérifiez le Wi-Fi et l\'adresse IP.',
      );
    }
  }

  /// Demande à un hôte de rejoindre sa session avec sa clé.
  Future<JoinResult> join({
    required Peer host,
    required String key,
    required String name,
    required String localAddress,
    required int localPort,
  }) async {
    final probe = await probeHost(host);
    if (!probe.reachable) return JoinResult.failure(probe.error ?? 'Hôte injoignable');

    final uri = Uri(
      scheme: 'http',
      host: host.hostForUri,
      port: host.port,
      path: '/api/session/join',
      queryParameters: {
        'key': key,
        'name': name,
        'address': localAddress,
        'port': localPort.toString(),
      },
    );

    try {
      final request = await _client.postUrl(uri);
      request.contentLength = 0;
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 404) {
        return JoinResult.failure(
          'L\'hôte a changé d\'adresse IP (404). Actualisez le réseau '
          'ou scannez à nouveau son QR code.',
        );
      }
      if (response.statusCode != 200) {
        return JoinResult.failure('HTTP ${response.statusCode}: $body');
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final peers = (decoded['peers'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(Peer.fromJson)
          .toList();
      return JoinResult.success(peers);
    } catch (error) {
      return JoinResult.failure(error.toString());
    }
  }

  /// Envoie à tous les appareils la liste mise à jour des connectés.
  Future<bool> pushPeers(
    Peer peer, {
    required String key,
    required List<Peer> peers,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: peer.hostForUri,
      port: peer.port,
      path: '/api/session/peers',
      queryParameters: {'key': key},
    );
    try {
      final request = await _client.postUrl(uri);
      final payload = jsonEncode(peers.map((p) => p.toJson()).toList());
      final bytes = utf8.encode(payload);
      request.contentLength = bytes.length;
      request.headers.contentType = ContentType.json;
      request.add(bytes);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Envoie un fichier à un appareil de la session.
  Future<SendResult> send(
    Peer peer,
    File file, {
    required String key,
    void Function(double progress)? onProgress,
  }) async {
    final total = file.lengthSync();
    final uri = Uri(
      scheme: 'http',
      host: peer.hostForUri,
      port: peer.port,
      path: '/api/transfer',
      queryParameters: {
        'key': key,
        'name': p.basename(file.path),
        'size': total.toString(),
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );

    try {
      final request = await _client.postUrl(uri);
      request.headers.contentType = ContentType.binary;
      request.contentLength = total;

      var sent = 0;
      final stream = file.openRead().transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleData: (data, sink) {
                sent += data.length;
                onProgress?.call(total <= 0 ? 1.0 : sent / total);
                sink.add(data);
              },
            ),
          );

      await stream.pipe(request);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        return SendResult.failure('HTTP ${response.statusCode}: $body');
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return SendResult.success(
        decoded['saved'] as String? ?? p.basename(file.path),
      );
    } catch (error) {
      return SendResult.failure(error.toString());
    }
  }

  void close() => _client.close();
}
