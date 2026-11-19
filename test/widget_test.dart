import 'package:flutter_test/flutter_test.dart';

import 'package:alefa_ara/models/scan_result.dart';
import 'package:alefa_ara/models/transfer.dart';

void main() {
  test('formatBytes affiche une unité lisible', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
  });

  test('le QR code Alefa arà est lu, ancien schéma accepté', () {
    final result = ScanResult.tryParse(
      'alefaara://192.168.43.1:4587?k=482913&n=VG91ciBQQw%3D%3D',
    );
    expect(result?.address, '192.168.43.1');
    expect(result?.port, 4587);
    expect(result?.key, '482913');
    expect(result?.name, 'Tour PC');

    final legacy = ScanResult.tryParse('omeo://10.0.0.5?k=123456');
    expect(legacy?.key, '123456');
    expect(legacy?.port, 4587);
    expect(ScanResult.tryParse('https://exemple.com'), isNull);

    final withWifi = ScanResult.tryParse(
      'alefaara://192.168.43.1:4587?k=123456'
      '&s=SG90c3BvdA&w=c2VjcmV0',
    );
    expect(withWifi?.ssid, 'Hotspot');
    expect(withWifi?.password, 'secret');
  });
}
