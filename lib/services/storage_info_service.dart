import 'dart:io';

import 'package:disk_usage/disk_usage.dart';

class StorageInfo {
  final int freeBytes;
  final int totalBytes;
  final int appBytes;
  final int fileCount;

  const StorageInfo({
    required this.freeBytes,
    required this.totalBytes,
    required this.appBytes,
    required this.fileCount,
  });

  double get usedRatio =>
      totalBytes <= 0 ? 0 : (1 - freeBytes / totalBytes).clamp(0.0, 1.0);
}

class StorageInfoService {
  const StorageInfoService(this.directory);

  final String directory;

  Future<StorageInfo> read() async {
    int appBytes = 0;
    int fileCount = 0;

    final dir = Directory(directory);
    if (dir.existsSync()) {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          appBytes += entity.lengthSync();
          fileCount++;
        }
      }
    }

    int? free;
    int? total;
    try {
      free = await DiskUsage.freeSpace(directory);
      total = await DiskUsage.totalSpace(directory);
    } catch (_) {
      // Certaines plates-formes peuvent refuser la requête : on affiche
      // quand même l'espace utilisé par l'application.
    }

    return StorageInfo(
      freeBytes: free ?? 0,
      totalBytes: total ?? 0,
      appBytes: appBytes,
      fileCount: fileCount,
    );
  }
}
