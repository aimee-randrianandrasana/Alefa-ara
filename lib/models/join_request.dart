import 'dart:async';

/// Demande d'un appareil qui veut rejoindre la session de l'hôte.
class JoinRequest {
  final String name;
  final String address;
  final int port;
  final DateTime receivedAt;
  final Completer<bool> decision = Completer<bool>();

  JoinRequest({
    required this.name,
    required this.address,
    required this.port,
    required this.receivedAt,
  });

  bool get decided => decision.isCompleted;

  void accept() {
    if (!decision.isCompleted) decision.complete(true);
  }

  void refuse() {
    if (!decision.isCompleted) decision.complete(false);
  }
}
