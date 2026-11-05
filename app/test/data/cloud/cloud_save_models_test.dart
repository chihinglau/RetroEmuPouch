import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/data/cloud/cloud_save_models.dart';

// The 2026-11-05 disk cache for `GET /api/cloud/saves/list` serialises
// CloudSaveSummary through toJson/fromJson. These tests pin that on-disk
// contract so a future field rename cannot silently corrupt cached lists.
void main() {
  group('CloudSaveSummary disk-cache serialisation', () {
    CloudSaveSummary sample() => CloudSaveSummary(
          id: 'blob-42',
          saveName: '0BE9B81B.sav',
          sizeBytes: 12345,
          sha256: 'a' * 64,
          createdAt: DateTime.utc(2026, 11, 5, 9, 30, 1),
          updatedAt: DateTime.utc(2026, 11, 5, 10, 0, 2),
        );

    test('toJson / fromJson round-trips every field', () {
      final s = sample();
      final restored = CloudSaveSummary.fromJson(s.toJson());
      expect(restored.id, s.id);
      expect(restored.saveName, s.saveName);
      expect(restored.sizeBytes, s.sizeBytes);
      expect(restored.sha256, s.sha256);
      expect(restored.createdAt.millisecondsSinceEpoch,
          s.createdAt.millisecondsSinceEpoch);
      expect(restored.updatedAt.millisecondsSinceEpoch,
          s.updatedAt.millisecondsSinceEpoch);
    });

    test('keys match the backend list contract and dates are parseable ISO', () {
      final j = sample().toJson();
      expect(
        j.keys,
        unorderedEquals(<String>[
          'id',
          'save_name',
          'size_bytes',
          'sha256',
          'created_at',
          'updated_at',
        ]),
      );
      expect(DateTime.tryParse(j['created_at']! as String), isNotNull);
      expect(DateTime.tryParse(j['updated_at']! as String), isNotNull);
    });

    test('fromJson tolerates a partial / old cache entry', () {
      final r = CloudSaveSummary.fromJson(<String, dynamic>{
        'save_name': 'x.sav',
        'created_at': 'garbage',
      });
      expect(r.id, '');
      expect(r.saveName, 'x.sav');
      expect(r.sizeBytes, 0);
      expect(r.sha256, '');
      expect(r.createdAt, isA<DateTime>());
    });

    test('a list can be encoded and decoded as one cache blob', () {
      final list = <CloudSaveSummary>[
        sample(),
        CloudSaveSummary(
          id: 'blob-43',
          saveName: 'AABBCCDD.state',
          sizeBytes: 7,
          sha256: 'b' * 64,
          createdAt: DateTime.utc(2026, 11, 4),
          updatedAt: DateTime.utc(2026, 11, 4),
        ),
      ];
      // Mirrors CloudClient._persistList / _decodeList.
      final encoded = list.map((s) => s.toJson()).toList();
      final decoded = encoded
          .whereType<Map>()
          .map((m) => CloudSaveSummary.fromJson(m.cast<String, dynamic>()))
          .toList();
      expect(decoded, hasLength(2));
      expect(decoded.first.id, 'blob-42');
      expect(decoded.last.saveName, 'AABBCCDD.state');
    });
  });
}
