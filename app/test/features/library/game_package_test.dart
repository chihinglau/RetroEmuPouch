import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/data/package/game_package.dart';
import 'package:retroemupouch/domain/rom_entry.dart';

void main() {
  test('export streams large files and keeps Chinese names intact (no OOM / no mojibake)',
      () async {
    final filesDir = await Directory.systemTemp.createTemp('gp_export_');
    final importDir = await Directory.systemTemp.createTemp('gp_import_');
    try {
      // Chinese ROM *file name* exercises the ZIP entry-name UTF-8 path.
      final romBytes = Uint8List.fromList(
          List<int>.generate(2 * 1024 * 1024, (i) => i % 251));
      final romPath = '${filesDir.path}/roms/魂斗罗.nes';
      await File(romPath).create(recursive: true);
      await File(romPath).writeAsBytes(romBytes);

      const crc32 = 0x1234ABCD;
      final crcKey =
          (crc32 & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase();
      final saveBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final savePath = '${filesDir.path}/saves/$crcKey.sav';
      await File(savePath).create(recursive: true);
      await File(savePath).writeAsBytes(saveBytes);

      final entry = RomEntry(
        name: '魂斗罗 (Contra)',
        originalName: 'contra.nes',
        relativePath: 'roms/魂斗罗.nes',
        size: romBytes.length,
        crc32: crc32,
        importedAt: DateTime.now(),
        platform: PlatformKind.nes,
      );

      final zip = '${filesDir.path}/pkg.zip';
      await GamePackage(filesDir.path).buildPackage(
        [entry],
        zip,
        PackageOptions(
          includeSaves: true,
          includeCovers: false,
          includeCheats: false,
          includeBios: false,
        ),
      );

      final zipFile = File(zip);
      expect(await zipFile.exists(), isTrue);
      final zipSize = await zipFile.length();
      // Streamed writer produced a real archive.
      expect(zipSize, greaterThan(1000));

      // --- garble assertion: manifest content is valid UTF-8 with Chinese ---
      final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
      final manifestEntry = archive.findFile('manifest.json')!;
      final manifestText = utf8.decode(manifestEntry.content as List<int>);
      expect(manifestText.contains('魂斗罗 (Contra)'), isTrue);
      expect(manifestText.contains('魂斗罗.nes'), isTrue);
      // ROM entry name present in the archive under its Chinese name.
      expect(archive.findFile('roms/魂斗罗.nes'), isNotNull);

      // --- full import round-trip ---
      final result =
          await GamePackage(importDir.path).importPackage(File(zip));
      expect(result.wasPackage, isTrue);
      expect(result.entries.length, 1);
      expect(result.entries.first.name, '魂斗罗 (Contra)');
      final importedRom = File('${importDir.path}/roms/魂斗罗.nes');
      expect(await importedRom.exists(), isTrue);
      expect(await importedRom.readAsBytes(), romBytes);
      final importedSave = File('${importDir.path}/saves/$crcKey.sav');
      expect(await importedSave.exists(), isTrue);
      expect(await importedSave.readAsBytes(), saveBytes);
    } finally {
      await filesDir.delete(recursive: true);
      await importDir.delete(recursive: true);
    }
  });
}
