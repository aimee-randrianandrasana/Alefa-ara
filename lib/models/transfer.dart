enum TransferStatus { sending, receiving, done, failed, refused }

class Transfer {
  final String id;
  final String fileName;
  final int size;
  final int transferred;
  final String peerName;
  final bool outgoing;
  final TransferStatus status;
  final String? error;
  final DateTime createdAt;

  const Transfer({
    required this.id,
    required this.fileName,
    required this.size,
    this.transferred = 0,
    required this.peerName,
    required this.outgoing,
    required this.status,
    this.error,
    required this.createdAt,
  });

  double get progress =>
      size <= 0 ? (status == TransferStatus.done ? 1 : 0) : transferred / size;

  Transfer copyWith({
    int? transferred,
    TransferStatus? status,
    String? error,
  }) {
    return Transfer(
      id: id,
      fileName: fileName,
      size: size,
      transferred: transferred ?? this.transferred,
      peerName: peerName,
      outgoing: outgoing,
      status: status ?? this.status,
      error: error ?? this.error,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'size': size,
        'transferred': transferred,
        'peerName': peerName,
        'outgoing': outgoing,
        'status': status.name,
        'error': error,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Transfer.fromJson(Map<String, dynamic> json) => Transfer(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        transferred: (json['transferred'] as num?)?.toInt() ?? 0,
        peerName: json['peerName'] as String? ?? '',
        outgoing: json['outgoing'] as bool? ?? true,
        status: TransferStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => TransferStatus.failed,
        ),
        error: json['error'] as String?,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
