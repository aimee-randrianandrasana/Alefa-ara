# Alefa arà

Partage de fichiers sur le réseau local, sans Internet et sans serveur
externe. L'application fonctionne entre deux PC, deux téléphones ou un PC et
un téléphone.

Les appareils se trouvent entre eux par diffusion UDP, créent une session
protégée par une clé à six chiffres, puis transfèrent les fichiers en HTTP.
Chaque appareil doit être accepté par l'hôte, et chaque fichier doit être
accepté par le destinataire.

## Utilisation

1. Mettez les appareils sur le même réseau. Sur Android, le point d'accès
   s'ouvre depuis « Réseau, Wi-Fi partagé et stockage ». Le bouton indique si
   le hotspot est actif.
2. Sur l'hôte, créez une session et partagez le QR code ou la clé.
3. Sur l'autre appareil, scannez le QR code ou saisissez l'adresse IP et la
   clé. Si le QR code contient le Wi-Fi partagé, le téléphone s'y connecte
   avant de rejoindre la session.
4. Acceptez la demande sur l'hôte, puis envoyez le fichier. Le destinataire
   doit l'accepter avant la réception.

Les fichiers reçus sont enregistrés dans `<Documents>/Alefa arà`. L'historique
des transferts est conservé dans l'application.

## Compilation

```bash
flutter pub get
flutter analyze
flutter test

flutter build apk --release
flutter build linux --release
```

Les binaires sont générés dans :

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/linux/x64/release/bundle/alefa_ara`

## Limites

- Android n'autorise pas l'ouverture silencieuse d'un point d'accès joignable
  par un PC : l'application ouvre les réglages système.
- Sur Android 10 et plus, la connexion à un Wi-Fi partagé demande une
  confirmation du système.
- Les ports TCP 4587 et UDP 4588 doivent être autorisés sur le PC.
- Aucun chiffrement : à utiliser sur un réseau de confiance.
- Un transfert interrompu doit être relancé manuellement.
