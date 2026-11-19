import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:android_intent_plus/android_intent.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';

import '../models/join_request.dart';
import '../models/peer.dart';
import '../models/scan_result.dart';
import '../models/transfer.dart';
import '../services/discovery_service.dart';
import '../services/storage_info_service.dart';
import '../services/storage_service.dart';
import '../services/theme_service.dart';
import '../services/transfer_client.dart';
import '../services/wifi_service.dart';
import '../services/transfer_server.dart';
import 'scanner_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late StorageService _storage;
  late TransferServer _server;
  late DiscoveryService _discovery;
  late TransferClient _client;
  late StorageInfoService _storageInfoService;

  StreamSubscription<List<Peer>>? _peerSub;
  StreamSubscription<IncomingTransfer>? _incomingSub;
  StreamSubscription<JoinRequest>? _joinSub;
  StreamSubscription<List<Peer>>? _sessionPeersSub;

  final List<Peer> _peers = <Peer>[];
  final List<Peer> _connected = <Peer>[];
  final List<Transfer> _activeTransfers = <Transfer>[];
  final List<Transfer> _history = <Transfer>[];

  Peer? _hostPeer;
  ScanResult? _pendingJoin;
  String _deviceName = 'Alefa arà';
  String _localIp = '...';
  String? _discoveryError;
  StorageInfo? _storageInfo;
  int _tab = 0;
  bool _ready = false;
  bool _hotspotActive = false;
  String? _sharedWifiSsid;

  static String get _platformName {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  static bool get _canScan =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quand on revient des réglages Wi-Fi (point d'accès), l'adresse IP a
    // souvent changé : on se remet à jour automatiquement.
    if (state == AppLifecycleState.resumed && _ready) {
      unawaited(_onResume());
    }
  }

  Future<void> _bootstrap() async {
    _storage = await StorageService.create();
    _deviceName = _storage.deviceName ?? _defaultName();
    await _storage.setDeviceName(_deviceName);
    _history.addAll(_storage.history);

    _localIp = await _readLocalIp();

    final documents = await getApplicationDocumentsDirectory();
    final newDir = p.join(documents.path, 'Alefa arà');
    for (final oldName in ['Omeo', 'Alefa ara']) {
      final oldDir = p.join(documents.path, oldName);
      if (oldDir == newDir || !Directory(oldDir).existsSync()) continue;
      try {
        if (!Directory(newDir).existsSync()) {
          await Directory(oldDir).rename(newDir);
        }
      } catch (_) {
        // On garde les anciens fichiers là où ils sont si le déplacement échoue.
      }
    }
    final receiveDir = newDir;
    _storageInfoService = StorageInfoService(receiveDir);

    _server = TransferServer(
      deviceName: _deviceName,
      platform: _platformName,
      saveDirectory: receiveDir,
      onFileSaved: _onFileSaved,
    )..localAddress = _localIp;

    final port = await _server.start();
    _client = TransferClient();

    _discovery = DiscoveryService();
    try {
      await _discovery.start(
        name: _deviceName,
        platform: _platformName,
        port: port,
      );
    } catch (error) {
      _discoveryError = error.toString();
    }

    _peerSub = _discovery.peers.listen((peers) {
      if (!mounted) return;
      setState(() {
        _peers
          ..clear()
          ..addAll(peers);
      });
    });
    _incomingSub = _server.incoming.listen(_showIncomingDialog);
    _joinSub = _server.joinRequests.listen(_showJoinRequestDialog);
    _sessionPeersSub = _server.sessionPeers.listen(_onSessionPeersChanged);

    _sharedWifiSsid = _storage.sharedWifiSsid;
    await _refreshStorage();
    await _checkHotspot();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _onResume() async {
    await _checkHotspot();
    await _refreshNetwork(showMessage: true);
    final pending = _pendingJoin;
    if (pending == null) return;
    _pendingJoin = null;
    // La connexion Wi-Fi a pu être acceptée pendant qu'on était en arrière-plan :
    // on retente alors la connexion à la session avec la nouvelle adresse IP.
    await _joinSession(
      host: Peer.manual(
        name: pending.name,
        address: pending.address,
        port: pending.port,
      ),
      key: pending.key,
    );
  }

  Future<void> _checkHotspot() async {
    if (!Platform.isAndroid) return;
    final active = await WifiService.instance.isHotspotActive(
      knownSsid: _sharedWifiSsid,
    );
    if (!mounted || active == _hotspotActive) return;
    setState(() => _hotspotActive = active);
  }

  String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty && host.toLowerCase() != 'localhost') return host;
    } catch (_) {}
    return 'Alefa arà-$_platformName-${1000 + Random().nextInt(9000)}';
  }

  Future<String> _readLocalIp() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (_) {}
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.address.startsWith('127.')) return address.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> _refreshStorage() async {
    final info = await _storageInfoService.read();
    if (!mounted) return;
    setState(() => _storageInfo = info);
  }

  /// Relecture de l'IP, redémarrage de la découverte si le réseau a changé,
  /// puis suppression des appareils qui ne répondent plus au test `/health`.
  Future<void> _refreshNetwork({bool showMessage = false}) async {
    final previousIp = _localIp;
    _localIp = await _readLocalIp();
    _server.localAddress = _localIp;

    try {
      if (_localIp != previousIp) {
        await _discovery.start(
          name: _deviceName,
          platform: _platformName,
          port: _server.port ?? 4587,
        );
      } else {
        await _discovery.refresh();
      }
    } catch (error) {
      if (mounted) setState(() => _discoveryError = error.toString());
    }

    final stale = <Peer>[];
    for (final peer in _discovery.currentPeers) {
      if (!await _client.isReachable(peer)) stale.add(peer);
    }
    for (final peer in stale) {
      _discovery.remove(peer.id);
    }

    if (!mounted) return;
    setState(() {});
    if (showMessage) {
      final changed = _localIp != previousIp ? ' • IP changée' : '';
      final removed = stale.isEmpty
          ? ''
          : ' • ${stale.length} appareil(s) injoignable(s) retiré(s)';
      _showMessage('Réseau actualisé : $_localIp$changed$removed');
    }
  }

  Future<void> _openHotspotSettings() async {
    // Android n'autorise pas une application à allumer un point d'accès
    // joignable par un PC sans confirmation : on ouvre les réglages système.
    const actions = <String>[
      'android.settings.TETHER_SETTINGS',
      'android.settings.WIRELESS_SETTINGS',
    ];
    for (final action in actions) {
      try {
        await AndroidIntent(action: action).launch();
        return;
      } catch (_) {}
    }
    _showMessage('Impossible d\'ouvrir les réglages réseau');
  }

  void _onFileSaved(String path, String name, int size) {
    if (!mounted) return;
    final transfer = Transfer(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: name,
      size: size,
      transferred: size,
      peerName: 'cet appareil',
      outgoing: false,
      status: TransferStatus.done,
      createdAt: DateTime.now(),
    );
    setState(() => _history.insert(0, transfer));
    unawaited(_storage.addHistory(transfer));
    unawaited(_refreshStorage());
  }

  void _onSessionPeersChanged(List<Peer> peers) {
    if (!mounted) return;
    setState(() => _connected
      ..clear()
      ..addAll(peers));
    if (_server.isHost) unawaited(_pushPeersToAll());
  }

  Future<void> _pushPeersToAll() async {
    final key = _server.sessionKey;
    if (!_server.isHost || key == null) return;
    final all = <Peer>[
      Peer.manual(name: _deviceName, address: _localIp, port: _server.port ?? 4587),
      ..._server.connectedPeers,
    ];
    for (final peer in _server.connectedPeers) {
      unawaited(_client.pushPeers(peer, key: key, peers: all));
    }
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _incomingSub?.cancel();
    _joinSub?.cancel();
    _sessionPeersSub?.cancel();
    unawaited(_server.stop());
    _server.dispose();
    _discovery.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alefa arà'),
        actions: [
          IconButton(
            tooltip: 'Actualiser le réseau',
            icon: const Icon(Icons.network_check),
            onPressed: _ready
                ? () => unawaited(_refreshNetwork(showMessage: true))
                : null,
          ),
          IconButton(
            tooltip: ThemeService.instance.label,
            icon: Icon(ThemeService.instance.icon),
            onPressed: () => unawaited(ThemeService.instance.cycle()),
          ),
          IconButton(
            tooltip: 'Nom de l\'appareil',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _ready ? _editDeviceName : null,
          ),
        ],
      ),
      floatingActionButton: _ready
          ? FloatingActionButton.extended(
              onPressed: _pickAndSend,
              icon: const Icon(Icons.send),
              label: const Text('Envoyer'),
            )
          : null,
      bottomNavigationBar: _ready
          ? NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (index) => setState(() => _tab = index),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Accueil',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.people_outline),
                  selectedIcon: const Icon(Icons.people),
                  label: _connected.isEmpty
                      ? 'Connectés'
                      : 'Connectés (${_connected.length})',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.history),
                  label: 'Historique',
                ),
              ],
            )
          : null,
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: IndexedStack(
                index: _tab,
                children: [_buildHome(), _buildConnected(), _buildHistory()],
              ),
            ),
    );
  }

  Widget _buildHome() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _heroCard(),
        const SizedBox(height: 20),
        Row(
          children: [
            Text(
              'Appareils à proximité (${_peers.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Actualiser le réseau',
              icon: const Icon(Icons.refresh),
              onPressed: () => unawaited(_refreshNetwork(showMessage: true)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_peers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Aucun appareil pour le moment. Mettez les appareils sur le '
              'même Wi-Fi, ou scannez le QR code de l\'hôte.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          ..._peers.map(_discoveredTile),
        if (_activeTransfers.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Transferts en cours',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ..._activeTransfers.map(_transferTile),
        ],
        if (_discoveryError != null) ...[
          const SizedBox(height: 16),
          Text(
            'Découverte automatique indisponible : $_discoveryError',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _showDetailsSheet,
          icon: const Icon(Icons.tune),
          label: const Text('Réseau, Wi-Fi partagé et stockage'),
        ),
      ],
    );
  }

  /// Une seule carte principale : l'action à faire, pas un tableau de bord.
  Widget _heroCard() {
    final active = _server.isSessionActive;
    final host = _server.isHost;
    return Card(
      color: active
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(child: Icon(_platformIcon(_platformName))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _deviceName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        active
                            ? (host
                                ? 'Hôte de la session'
                                : 'Connecté à ${_hostPeer?.name ?? 'l\'hôte'}')
                            : 'Prêt à partager • $_localIp',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (!active) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _createSession,
                icon: const Icon(Icons.lock_outline),
                label: const Text('Créer une session'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_canScan)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _scanQr,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scanner'),
                      ),
                    ),
                  if (_canScan) const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _showManualJoinDialog,
                      icon: const Icon(Icons.login),
                      label: const Text('Rejoindre'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 16),
              if (host) ...[
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(10),
                    child: QrImageView(
                      data: _qrData(),
                      version: QrVersions.auto,
                      size: 170,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _server.sessionKey ?? '',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          letterSpacing: 8,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _copyKey(_server.sessionKey ?? ''),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copier la clé'),
                  ),
                ),
              ] else
                Text(
                  '${_connected.length} appareil(s) dans la session. '
                  'Les fichiers doivent être acceptés un par un.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _leaveSession,
                icon: const Icon(Icons.logout),
                label: const Text('Quitter la session'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Les détails techniques ne prennent plus la place à l'accueil.
  Future<void> _showDetailsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Réseau et stockage',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              _networkDetails(),
              const Divider(height: 32),
              _storageDetails(),
              const Divider(height: 32),
              _wifiDetails(),
            ],
          ),
        ),
      ),
    );
    await _checkHotspot();
  }

  Widget _networkDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.router),
            const SizedBox(width: 8),
            Text(
              'Réseau local',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Actualiser le réseau',
              icon: const Icon(Icons.refresh),
              onPressed: () => unawaited(_refreshNetwork(showMessage: true)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Cet appareil : $_localIp:${_server.port ?? 4587}'),
        const SizedBox(height: 8),
        Text(
          Platform.isAndroid
              ? 'Activez le point d\'accès du téléphone, connectez-y le PC '
                  'et les autres téléphones, puis revenez dans l\'application.'
              : 'Connectez tous les appareils au même Wi-Fi ou au point '
                  'd\'accès d\'un téléphone.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (Platform.isAndroid) ...[
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () async {
              await _openHotspotSettings();
              await _checkHotspot();
            },
            icon: Icon(
              _hotspotActive ? Icons.check_circle : Icons.wifi_tethering,
            ),
            label: Text(
              _hotspotActive
                  ? 'Point d\'accès actif • gérer'
                  : 'Ouvrir le point d\'accès',
            ),
          ),
        ],
      ],
    );
  }

  Widget _storageDetails() {
    final info = _storageInfo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.storage),
            const SizedBox(width: 8),
            Text(
              'Stockage',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Actualiser le stockage',
              icon: const Icon(Icons.refresh),
              onPressed: _refreshStorage,
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (info == null)
          const Text('Calcul en cours...')
        else ...[
          if (info.totalBytes > 0) ...[
            Text(
              '${formatBytes(info.freeBytes)} libres sur '
              '${formatBytes(info.totalBytes)}',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: info.usedRatio),
            const SizedBox(height: 8),
          ],
          Text(
            '${formatBytes(info.appBytes)} utilisés par Alefa arà '
            '(${info.fileCount} fichier(s) reçu(s))',
          ),
        ],
      ],
    );
  }

  Widget _wifiDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.wifi),
            const SizedBox(width: 8),
            Text(
              'Wi-Fi partagé',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _sharedWifiSsid == null
              ? 'Non configuré. Indiquez le réseau Wi-Fi de cet appareil : '
                  'les autres téléphones pourront le rejoindre '
                  'automatiquement en scannant votre QR code.'
              : 'Réseau diffusé dans le QR code : $_sharedWifiSsid',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _showWifiSetupDialog,
              icon: const Icon(Icons.edit),
              label: Text(
                _sharedWifiSsid == null ? 'Configurer' : 'Modifier',
              ),
            ),
            if (_sharedWifiSsid != null) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  await _storage.clearSharedWifi();
                  if (!mounted) return;
                  setState(() => _sharedWifiSsid = null);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Effacer'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _discoveredTile(Peer peer) {
    final alreadyConnected =
        _connected.any((item) => item.address == peer.address);
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(_platformIcon(peer.platform))),
        title: Text(peer.name),
        subtitle: Text('${peer.address}:${peer.port}'),
        trailing: alreadyConnected
            ? const Icon(Icons.check_circle, color: Colors.green)
            : IconButton(
                tooltip: 'Se connecter',
                icon: const Icon(Icons.link),
                onPressed: () => _showManualJoinDialog(
                  initialAddress: peer.address,
                  initialPort: peer.port,
                ),
              ),
      ),
    );
  }

  Widget _buildConnected() {
    if (!_server.isSessionActive) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.people_outline, size: 48),
              const SizedBox(height: 16),
              Text(
                'Aucune session active',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Créez une session ou scannez le QR code d\'un hôte '
                'pour voir apparaître les appareils connectés ici.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Appareils connectés (${_connected.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (_connected.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'En attente d\'appareils. Partagez votre clé ou votre QR code.',
              textAlign: TextAlign.center,
            ),
          )
        else
          ..._connected.map(
            (peer) => Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Icon(
                    peer.address == _hostPeer?.address
                        ? Icons.dns
                        : Icons.smartphone,
                  ),
                ),
                title: Text(peer.name),
                subtitle: Text(
                  '${peer.address}:${peer.port}'
                  '${peer.address == _hostPeer?.address ? ' • hôte' : ''}',
                ),
                trailing: IconButton(
                  tooltip: 'Envoyer un fichier',
                  icon: const Icon(Icons.send),
                  onPressed: () => _sendToPeer(peer),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHistory() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(
                'Historique',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  await _storage.clearHistory();
                  if (!mounted) return;
                  setState(() => _history.clear());
                },
                child: const Text('Effacer'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _history.isEmpty
              ? const Center(child: Text('Aucun transfert pour le moment'))
              : ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final transfer = _history[index];
                    return ListTile(
                      leading: Icon(transfer.outgoing
                          ? Icons.upload
                          : Icons.download),
                      title: Text(transfer.fileName),
                      subtitle: Text(
                        '${transfer.outgoing ? 'Envoyé à' : 'Reçu de'} '
                        '${transfer.peerName} • ${formatBytes(transfer.size)}',
                      ),
                      trailing: transfer.outgoing
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.open_in_new),
                              onPressed: () => unawaited(
                                OpenFilex.open(
                                  p.join(_server.saveDirectory, transfer.fileName),
                                ),
                              ),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _transferTile(Transfer transfer) {
    final color = switch (transfer.status) {
      TransferStatus.done => Colors.green,
      TransferStatus.failed || TransferStatus.refused => Colors.red,
      _ => null,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  transfer.outgoing ? Icons.upload : Icons.download,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    transfer.fileName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(formatBytes(transfer.size)),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: transfer.progress.clamp(0.0, 1.0)),
            if (transfer.error != null) ...[
              const SizedBox(height: 4),
              Text(
                transfer.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _platformIcon(String platform) => switch (platform) {
        'android' || 'ios' => Icons.smartphone,
        'windows' => Icons.desktop_windows,
        'macos' => Icons.laptop_mac,
        'linux' => Icons.computer,
        _ => Icons.devices,
      };

  String _qrData() {
    final key = _server.sessionKey ?? '';
    final uri = Uri(
      scheme: 'alefaara',
      host: _localIp,
      port: _server.port ?? 4587,
      queryParameters: {
        'k': key,
        'n': base64Url.encode(utf8.encode(_deviceName)),
        if (_sharedWifiSsid != null)
          's': base64Url.encode(utf8.encode(_sharedWifiSsid!)),
        if (_storage.sharedWifiPassword != null)
          'w': base64Url.encode(utf8.encode(_storage.sharedWifiPassword!)),
      },
    );
    return uri.toString();
  }

  Future<void> _showWifiSetupDialog() async {
    final ssidController =
        TextEditingController(text: _storage.sharedWifiSsid ?? '');
    final passwordController =
        TextEditingController(text: _storage.sharedWifiPassword ?? '');
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wi-Fi partagé'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ces informations sont intégrées au QR code pour que les '
              'autres appareils rejoignent automatiquement votre réseau.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ssidController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nom du réseau (SSID)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Mot de passe (laisser vide si réseau ouvert)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (result != true || !mounted) return;
    final ssid = ssidController.text.trim();
    if (ssid.isEmpty) return;
    await _storage.setSharedWifi(ssid, passwordController.text);
    if (!mounted) return;
    setState(() => _sharedWifiSsid = ssid);
    _showMessage('Wi-Fi « $ssid » ajouté au QR code');
  }

  Future<void> _copyKey(String key) async {
    await Clipboard.setData(ClipboardData(text: key));
    _showMessage('Clé copiée : $key');
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _createSession() {
    final key = _server.startSession();
    setState(() {
      _hostPeer = null;
      _connected.clear();
    });
    _showMessage('Session créée. Clé : $key');
  }

  void _leaveSession() {
    unawaited(WifiService.instance.releaseWifiUsage());
    _server.leaveSession();
    setState(() {
      _hostPeer = null;
      _connected.clear();
    });
    _showMessage('Session quittée');
  }

  Future<void> _scanQr() async {
    final result = await Navigator.push<ScanResult>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (result == null || !mounted) return;

    if (result.ssid != null && (Platform.isAndroid || Platform.isIOS)) {
      _showMessage('Connexion au Wi-Fi « ${result.ssid} »...');
      final connected = await WifiService.instance.connectToSharedNetwork(
        ssid: result.ssid!,
        password: result.password,
      );
      if (!connected) {
        _pendingJoin = result;
        _showMessage(
          'Wi-Fi non connecté. Acceptez la demande du système, puis '
          'revenez dans l\'application : la connexion reprendra.',
        );
        if (Platform.isAndroid) await _openWifiSettings();
        return;
      }
      // Laisse le système terminer la négociation Wi-Fi avant de relire l'IP.
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshNetwork();
    }

    await _joinSession(
      host: Peer.manual(
        name: result.name,
        address: result.address,
        port: result.port,
      ),
      key: result.key,
    );
  }

  /// Le QR peut contenir une IP obsolète (PC avec plusieurs cartes réseau).
  /// On essaie donc l'annonce UDP portant le même nom avant d'abandonner.
  Future<Peer> _resolveHostPeer(Peer host) async {
    if ((await _client.probeHost(host)).reachable) return host;
    final candidates = <Peer>[
      ..._peers.where((peer) => peer.name == host.name),
      ..._peers.where((peer) => peer.name != host.name),
    ];
    for (final candidate in candidates) {
      if ((await _client.probeHost(candidate)).reachable) return candidate;
    }
    return host;
  }

  Future<void> _joinSession({required Peer host, required String key}) async {
    if (_server.isSessionActive) {
      _showMessage('Quittez d\'abord la session actuelle');
      return;
    }
    if (key.trim().length != 6) {
      _showMessage('La clé doit contenir 6 chiffres');
      return;
    }

    final target = await _resolveHostPeer(host);
    final result = await _client.join(
      host: target,
      key: key.trim(),
      name: _deviceName,
      localAddress: _localIp,
      localPort: _server.port ?? 4587,
    );
    if (!result.ok || !mounted) {
      _showMessage('Connexion impossible : ${result.error}');
      return;
    }

    _server.joinSession(key: key.trim(), host: target);
    setState(() {
      _hostPeer = result.peers.firstWhere(
        (peer) => peer.address == target.address,
        orElse: () => target,
      );
      _connected
        ..clear()
        ..addAll(result.peers.where(
          (peer) => peer.address != _localIp && peer.address != target.address,
        ));
    });
    _showMessage('Connecté à ${target.name}');
  }

  Future<void> _openWifiSettings() async {
    for (final action in const <String>[
      'android.settings.WIFI_SETTINGS',
      'android.settings.WIRELESS_SETTINGS',
    ]) {
      try {
        await AndroidIntent(action: action).launch();
        return;
      } catch (_) {}
    }
  }

  void _showJoinRequestDialog(JoinRequest request) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Demande de connexion'),
        content: Text(
          '${request.name} (${request.address}) veut rejoindre votre session. '
          'N\'acceptez que les appareils auxquels vous avez donné la clé.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              request.refuse();
              Navigator.pop(context);
            },
            child: const Text('Refuser'),
          ),
          FilledButton(
            onPressed: () {
              request.accept();
              Navigator.pop(context);
            },
            child: const Text('Accepter'),
          ),
        ],
      ),
    );
  }

  void _showIncomingDialog(IncomingTransfer incoming) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StreamBuilder<double>(
        stream: incoming.progress.stream,
        initialData: 0.0,
        builder: (context, snapshot) {
          final progress = (snapshot.data ?? 0).clamp(0.0, 1.0);
          final decided = incoming.accepted;
          return AlertDialog(
            title: Text(decided ? 'Réception en cours' : 'Fichier entrant'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  incoming.fileName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text('${formatBytes(incoming.size)} • ${incoming.fromAddress}'),
                if (decided) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: progress),
                ],
              ],
            ),
            actions: [
              if (!decided)
                TextButton(
                  onPressed: () {
                    incoming.refuse();
                    Navigator.pop(context);
                  },
                  child: const Text('Refuser'),
                ),
              if (!decided)
                FilledButton(
                  onPressed: incoming.accept,
                  child: const Text('Accepter'),
                ),
              if (decided)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Masquer'),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _deviceName);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nom de l\'appareil'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(labelText: 'Nom affiché'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;

    await _storage.setDeviceName(result);
    _server.deviceName = result;
    setState(() => _deviceName = result);
    _discovery.updateInfo(
      name: result,
      platform: _platformName,
      port: _server.port ?? 4587,
    );
  }

  Future<void> _showManualJoinDialog({
    String initialAddress = '',
    int? initialPort,
  }) async {
    final addressController = TextEditingController(text: initialAddress);
    final portController =
        TextEditingController(text: (initialPort ?? 4587).toString());
    final keyController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rejoindre une session'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressController,
              autofocus: initialAddress.isEmpty,
              decoration: const InputDecoration(labelText: 'Adresse IP de l\'hôte'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Clé à 6 chiffres donnée par l\'hôte',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final address = addressController.text.trim();
              final key = keyController.text.trim();
              if (address.isEmpty || key.isEmpty) return;
              Navigator.pop(context, {
                'address': address,
                'port': portController.text,
                'key': key,
              });
            },
            child: const Text('Se connecter'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    await _joinSession(
      host: Peer.manual(
        name: 'Hôte',
        address: result['address']!,
        port: int.tryParse(result['port'] ?? '') ?? 4587,
      ),
      key: result['key']!,
    );
  }

  Future<List<File>> _pickFiles() async {
    final picked = await FilePicker.pickFiles();
    if (!mounted) return const <File>[];
    return picked
        .where((file) => file.path != null)
        .map((file) => File(file.path!))
        .toList(growable: false);
  }

  Future<void> _pickAndSend() async {
    if (!_requireSession()) return;
    final files = await _pickFiles();
    if (files.isEmpty) return;

    final peer = await _selectConnectedPeer();
    if (peer == null || !mounted) return;
    for (final file in files) {
      await _sendFile(peer, file);
    }
  }

  Future<void> _sendToPeer(Peer peer) async {
    if (!_requireSession()) return;
    final files = await _pickFiles();
    for (final file in files) {
      await _sendFile(peer, file);
    }
  }

  bool _requireSession() {
    if (!_server.isSessionActive) {
      _showMessage('Créez ou rejoignez une session avant d\'envoyer');
      return false;
    }
    if (_connected.isEmpty) {
      _showMessage('Aucun appareil connecté à la session');
      return false;
    }
    return true;
  }

  Future<Peer?> _selectConnectedPeer() {
    return showModalBottomSheet<Peer>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Envoyer à',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ..._connected.map(
              (peer) => ListTile(
                leading: Icon(_platformIcon(peer.platform)),
                title: Text(peer.name),
                subtitle: Text('${peer.address}:${peer.port}'),
                onTap: () => Navigator.pop(context, peer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendFile(Peer peer, File file) async {
    final key = _server.sessionKey;
    if (key == null) return;

    // Un appareil aperçu il y a peu peut avoir changé d'IP : on vérifie
    // avant d'envoyer pour éviter les erreurs 404 sur une vieille adresse.
    if (!await _client.isReachable(peer)) {
      _discovery.remove(peer.id);
      _showMessage('${peer.name} n\'est plus joignable : actualisez le réseau');
      return;
    }

    final transfer = Transfer(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: p.basename(file.path),
      size: file.lengthSync(),
      peerName: peer.name,
      outgoing: true,
      status: TransferStatus.sending,
      createdAt: DateTime.now(),
    );
    setState(() => _activeTransfers.insert(0, transfer));

    final result = await _client.send(
      peer,
      file,
      key: key,
      onProgress: (progress) {
        if (!mounted) return;
        setState(() {
          final index =
              _activeTransfers.indexWhere((item) => item.id == transfer.id);
          if (index >= 0) {
            _activeTransfers[index] = transfer.copyWith(
              transferred: (progress * transfer.size).round(),
            );
          }
        });
      },
    );

    final finalTransfer = transfer.copyWith(
      transferred: result.ok ? transfer.size : transfer.transferred,
      status: result.ok ? TransferStatus.done : TransferStatus.failed,
      error: result.error,
    );
    if (!mounted) return;
    setState(() {
      final index =
          _activeTransfers.indexWhere((item) => item.id == transfer.id);
      if (index >= 0) _activeTransfers[index] = finalTransfer;
    });
    await _storage.addHistory(finalTransfer);
  }
}
