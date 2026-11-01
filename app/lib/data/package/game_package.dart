import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:retroemupouch/data/peer/peer_files.dart';
import 'package:path/path.dart' as p;

import '../../domain/rom_entry.dart';
import '../../system_files.dart';
import '../rom_library.dart';
import '../play/multiplayer_catalog.dart';

/// A single game captured inside a gamepouch resource package.
class PackageGame {
  PackageGame({
    required this.crc32,
    required this.crcKey,
    required this.platform,
    this.driverName,
    required this.romPath,
    this.coverPath,
    required this.savePaths,
    required this.hasCheats,
    required this.entry,
  });

  final int crc32;
  final String crcKey;
  final String platform;
  final String? driverName;
  final String romPath;
  final String? coverPath;
  final List<String> savePaths;
  final bool hasCheats;
  final Map<String, dynamic> entry;

  Map<String, dynamic> toJson() => {
        'crc32': crc32,
        'crcKey': crcKey,
        'platform': platform,
        if (driverName != null) 'driverName': driverName,
        'romPath': romPath,
        if (coverPath != null) 'coverPath': coverPath,
        'savePaths': savePaths,
        'hasCheats': hasCheats,
        'entry': entry,
      };

  factory PackageGame.fromJson(Map<String, dynamic> j) => PackageGame(
        crc32: j['crc32'] as int,
        crcKey: j['crcKey'] as String,
        platform: j['platform'] as String,
        driverName: j['driverName'] as String?,
        romPath: j['romPath'] as String,
        coverPath: j['coverPath'] as String?,
        savePaths: (j['savePaths'] as List).cast<String>(),
        hasCheats: j['hasCheats'] as bool? ?? false,
        entry: Map<String, dynamic>.from(j['entry'] as Map),
      );
}

/// `gamepouch.package` manifest stored at the ZIP root (`manifest.json`).
class GamePackageManifest {
  GamePackageManifest({
    required this.games,
    required this.appVersion,
    required this.createdAt,
    this.bios = const [],
  });

  final List<PackageGame> games;
  final String appVersion;
  final String createdAt;

  /// ZIP-relative paths of bundled BIOS blobs (e.g. `system/neogeo.zip`).
  /// Empty for packages built before BIOS support existed.
  final List<String> bios;

  Map<String, dynamic> toJson() => {
        'format': 'gamepouch.package',
        'schemaVersion': 2,
        'generator': 'GamePouch Android',
        'appVersion': appVersion,
        'createdAt': createdAt,
        'bios': bios,
        'games': games.map((g) => g.toJson()).toList(),
      };

  factory GamePackageManifest.fromJson(Map<String, dynamic> j) => GamePackageManifest(
        games: (j['games'] as List)
            .map((g) => PackageGame.fromJson(Map<String, dynamic>.from(g as Map)))
            .toList(),
        appVersion: j['appVersion'] as String? ?? '',
        createdAt: j['createdAt'] as String? ?? '',
        bios: (j['bios'] as List?)?.cast<String>() ?? const [],
      );
}

/// Resources to bundle when exporting a package.
class PackageOptions {
  const PackageOptions({
    this.includeCheats = true,
    this.includeSaves = true,
    this.includeCovers = true,
    this.includeBios = false,
    this.biosNames = const [],
  });
  final bool includeCheats;
  final bool includeSaves;
  final bool includeCovers;

  /// When true, the BIOS blobs named in [biosNames] (already installed under
  /// `<filesDir>/system/`, e.g. neogeo.zip / qsound.zip) are bundled into the
  /// package so the receiving device can boot arcade games without a separate
  /// trip to 设置 → 系统文件（BIOS）.
  final bool includeBios;

  /// BIOS file names to bundle (only honoured when [includeBios] is true).
  final List<String> biosNames;
}

/// Outcome of [GamePackage.importPackage].
class PackageImportResult {
  PackageImportResult({
    required this.entries,
    required this.wasPackage,
    required this.cheatCount,
    required this.saveCount,
    this.biosCount = 0,
  });
  final List<RomEntry> entries;
  final bool wasPackage;
  final int cheatCount;
  final int saveCount;

  /// BIOS blobs restored into `<filesDir>/system/` from the package.
  final int biosCount;
}

/// Offline share format: a ZIP with a `manifest.json` describing each game
/// plus its ROM / cheats / saves / cover, importable on another device with
/// no network (USB / 蓝牙 / 微信文件 transfer). Plain ROM zips are also
/// recognised on import.

/// Reports package-build progress: [done]/[total] units finished, with a
/// human-readable [label] for the current unit.
typedef BuildProgress = void Function(int done, int total, String? label);

class GamePackage {
  GamePackage(this.filesDir);

  final String filesDir;

  /// Builds a ZIP resource package from [entries] and writes it to
  /// [outputZip]. Returns the written file. [appVersion] seeds the manifest;
  /// callers should pass the live `PlatformPal.appVersion()` so the recorded
  /// version always matches the exporting build.
  /// [onProgress] reports build progress (units done / total, plus a human
  /// label) so callers can show a live indicator instead of freezing the UI
  /// while the (blocking) zip encode runs.
  Future<File> buildPackage(
    List<RomEntry> entries,
    String outputZip,
    PackageOptions options, {
    String appVersion = _appVersion,
    BuildProgress? onProgress,
  }) async {
    final out = File(outputZip);
    await out.parent.create(recursive: true);
    final zipEntries = <_ZipEntry>[];
    final games = <PackageGame>[];
    final cheatMap = <String, dynamic>{};
    final lib = RomLibrary(filesDir);

    try {
      var i = 0;
      for (final e in entries) {
        final romFile = File('$filesDir/${e.relativePath}');
        if (!romFile.existsSync()) continue; // skip missing ROMs
        zipEntries.add(_ZipEntry(name: e.relativePath, file: romFile.path));

        final savePaths = <String>[];
        if (options.includeSaves) {
          for (final s in _collectSaves(e)) {
            final rel = 'saves/${p.basename(s.path)}';
            zipEntries.add(_ZipEntry(name: rel, file: s.path));
            savePaths.add(rel);
          }
        }

        String? coverPath;
        if (options.includeCovers && e.coverRelative != null) {
          final cf = File('$filesDir/${e.coverRelative}');
          if (cf.existsSync()) {
            coverPath = e.coverRelative;
            zipEntries.add(_ZipEntry(name: coverPath!, file: cf.path));
          }
        }

        var hasCheats = false;
        if (options.includeCheats) {
          final cmds = lib.cheatCommandsForCrc(e.crcKey);
          if (cmds.isNotEmpty) {
            cheatMap[e.crcKey] = cmds;
            hasCheats = true;
          }
        }

        games.add(PackageGame(
          crc32: e.crc32,
          crcKey: e.crcKey,
          platform: e.platform.name,
          driverName: MultiplayerCatalog.driverFromFileName(e.driverFileName),
          romPath: e.relativePath,
          coverPath: coverPath,
          savePaths: savePaths,
          hasCheats: hasCheats,
          entry: e.toJson(),
        ));

        i++;
        onProgress?.call(i, entries.length, '正在打包：${e.name}');
        await Future.delayed(Duration.zero); // yield so the UI can repaint
      }

      if (options.includeCheats && cheatMap.isNotEmpty) {
        zipEntries.add(_ZipEntry.bytes(
            'cheats.json',
            utf8.encode(const JsonEncoder.withIndent('  ').convert({
              'version': 1,
              'byCrc': cheatMap,
            }))));
      }

      // Bundle the selected BIOS blobs (already installed under
      // `<filesDir>/system/`) so the receiving device can boot arcade games
      // without a separate 设置 → 系统文件（BIOS）trip. Stored at the same
      // `system/<name>` path they occupy on device; import restores them there
      // and SystemFiles.syncAll mirrors into per-core dirs (e.g. mame/roms).
      final biosPaths = <String>[];
      if (options.includeBios) {
        final sysBase = '$filesDir/system';
        for (final name in options.biosNames) {
          final srcPath = SystemFiles.biosFilePath(sysBase, name);
          if (srcPath == null) continue;
          final src = File(srcPath);
          if (!src.existsSync()) continue;
          final rel = 'system/$name';
          zipEntries.add(_ZipEntry(name: rel, file: src.path));
          biosPaths.add(rel);
        }
        onProgress?.call(i, entries.length + biosPaths.length, '正在打包：系统文件');
      }

      zipEntries.add(_ZipEntry.bytes(
          'manifest.json',
          utf8.encode(const JsonEncoder.withIndent('  ').convert(GamePackageManifest(
            games: games,
            appVersion: appVersion,
            createdAt: DateTime.now().toIso8601String(),
            bios: biosPaths,
          ).toJson()))));

      // Stream the ZIP to disk in one pass: each source is read in chunks and
      // raw-deflated in chunks, so peak memory is ~one chunk regardless of ROM
      // size. This replaces archive's ZipEncoder, which buffered the whole file
      // in RAM (`bytes.toUint8List()` + `Deflate().getBytes()`) and crashed
      // (OOM) when exporting large game resource packages.
      await _streamZip(out, zipEntries, onProgress: onProgress);
      return out;
    } finally {
      // Per-entry files are opened with openRead(); the stream closes itself
      // once the deflate pipeline finishes consuming it.
    }
  }

  /// Parses [zip] and imports everything into [filesDir], auto-detecting a
  /// gamepouch resource package (manifest.json present) vs a plain ROM zip.
  ///
  /// The ZIP is streamed from disk (see [_importFromArchive]) rather than loaded
  /// entirely into RAM. The previous `zip.readAsBytes()` + `decodeBytes()` path
  /// held the whole archive (and every entry's compressed bytes) in memory, so a
  /// 70-game resource package (hundreds of MB) was killed by the device
  /// low-memory killer on phones ("无法导入游戏资源包"). With an
  /// `InputFileStream` the archive package keeps file-backed lazy views and only
  /// decompresses the entries we actually extract — peak memory is one ROM at a
  /// time, matching the already-streamed export path.
  Future<PackageImportResult> importPackage(File zip) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      return await _importFromArchive(archive);
    } finally {
      input.close();
    }
  }

  Future<PackageImportResult> _importFromArchive(Archive archive) async {

    final manifestEntry = archive.findFile('manifest.json');
    GamePackageManifest? manifest;
    if (manifestEntry != null) {
      try {
        manifest = GamePackageManifest.fromJson(repairJsonMojibake(jsonDecode(
            utf8.decode(manifestEntry.content as List<int>,
                allowMalformed: true))) as Map<String, dynamic>);
      } catch (_) {
        manifest = null;
      }
    }

    final imported = <RomEntry>[];
    var cheatCount = 0;
    var saveCount = 0;
    var biosCount = 0;

    if (manifest != null) {
      for (final g in manifest.games) {
        final rom = archive.findFile(g.romPath);
        if (rom == null) continue;
        final dest = File('$filesDir/${g.romPath}')
          ..parent.createSync(recursive: true);
        await dest.writeAsBytes(rom.content as List<int>);

        // entry JSON already carries relativePath + coverRelative, so no
        // post-construction assignment is needed (both fields are final).
        final entry = RomEntry.fromJson(g.entry);

        for (final sp in g.savePaths) {
          final sf = archive.findFile(sp);
          if (sf == null) continue;
          final d = File('$filesDir/$sp')..parent.createSync(recursive: true);
          await d.writeAsBytes(sf.content as List<int>);
          saveCount++;
        }
        if (g.coverPath != null) {
          final cf = archive.findFile(g.coverPath!);
          if (cf != null) {
            final d = File('$filesDir/${g.coverPath}')
              ..parent.createSync(recursive: true);
            await d.writeAsBytes(cf.content as List<int>);
          }
        }
        imported.add(entry);
      }

      final cheatsEntry = archive.findFile('cheats.json');
      if (cheatsEntry != null) {
        try {
          final j = repairJsonMojibake(jsonDecode(utf8.decode(
              cheatsEntry.content as List<int>,
              allowMalformed: true))) as Map<String, dynamic>;
          final byCrc = j['byCrc'];
          if (byCrc is Map) {
            await RomLibrary(filesDir)
                .mergeCheatsByCrc(Map<String, dynamic>.from(byCrc));
            cheatCount = byCrc.length;
          }
        } catch (_) {/* best effort */}
      }

      // Restore bundled BIOS blobs into `<filesDir>/system/` (their on-device
      // home). The caller's _scanBios() runs SystemFiles.syncAll, which mirrors
      // them into per-core dirs (e.g. mame/roms) so the core can boot.
      for (final rel in manifest.bios) {
        final bf = archive.findFile(rel);
        if (bf == null) continue;
        final dest = File('$filesDir/$rel')
          ..parent.createSync(recursive: true);
        await dest.writeAsBytes(bf.content as List<int>);
        biosCount++;
      }
      return PackageImportResult(
        entries: imported,
        wasPackage: true,
        cheatCount: cheatCount,
        saveCount: saveCount,
        biosCount: biosCount,
      );
    }

    // Plain ROM zip (or a single ROM): extract every rom-like entry.
    final seen = <String>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name;
      if (!_isRomName(name)) continue;
      final base = _uniqueRomName(seen, p.basename(name));
      seen.add(base);
      final rel = 'roms/$base';
      final dest = File('$filesDir/$rel')..parent.createSync(recursive: true);
      final content = f.content as List<int>;
      await dest.writeAsBytes(content);
      final crc = _crc32(content);
      imported.add(RomEntry(
        name: base,
        originalName: p.basename(name),
        relativePath: rel,
        size: content.length,
        crc32: crc,
        importedAt: DateTime.now(),
        platform: platformFromExtension(base, rel),
      ));
    }
    return PackageImportResult(
      entries: imported,
      wasPackage: false,
      cheatCount: 0,
      saveCount: 0,
    );
  }

  // --- helpers ---

  List<File> _collectSaves(RomEntry e) {
    final dir = Directory('$filesDir/saves');
    if (!dir.existsSync()) return const [];
    final keySet = <String>{e.crcKey.toLowerCase()};
    final driver = MultiplayerCatalog.driverFromFileName(e.name);
    if (driver.isNotEmpty) keySet.add(driver.toLowerCase());
    final out = <File>[];
    try {
      for (final ent in dir.listSync(followLinks: false)) {
        if (ent is! File) continue;
        final base = p.basename(ent.path);
        final stem = base.contains('.')
            ? base.substring(0, base.lastIndexOf('.'))
            : base;
        if (keySet.contains(stem.toLowerCase())) out.add(ent);
      }
    } catch (_) {/* ignore unreadable saves dir */}
    return out;
  }

  static bool _isRomName(String name) {
    final lower = name.toLowerCase();
    if (lower.startsWith('manifest') || lower.startsWith('cheats')) return false;
    final ext = lower.contains('.') ? lower.split('.').last : '';
    const romExt = {
      'nes', 'fds', 'unf', 'unif', 'sfc', 'smc', 'gb', 'gbc', 'sgb', 'gba',
      'z64', 'n64', 'v64', 'nds', 'a26', 'sms', 'gg', 'sg', 'md', 'gen',
      'smd', '32x', 'cue', 'pbp', 'mdf', 'img', 'iso', 'cso', 'zip',
    };
    return romExt.contains(ext);
  }

  static String _uniqueRomName(Set<String> seen, String name) {
    if (!seen.contains(name)) return name;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var i = 1;
    while (seen.contains('${base}_$i$ext')) {
      i++;
    }
    return '${base}_$i$ext';
  }

  /// Fallback manifest version when the caller does not supply one.
  static const String _appVersion = '1.8.4';
}

// --- streaming ZIP writer -------------------------------------------------
// Replaces archive's ZipEncoder, which materialised the *entire* input file in
// RAM (`bytes.toUint8List()` + `Deflate().getBytes()`) and OOM-killed the app
// on large ROMs. Here each source is read in chunks, the CRC32 is updated
// incrementally, and raw-deflate output is written to disk in chunks — peak
// memory is one chunk (~64 KB) no matter the ROM size. Names/content are UTF-8
// with the language-encoding flag set, so Chinese never mojibakes.

class _ZipEntry {
  _ZipEntry({required this.name, this.file, this.bytes})
      : assert((file == null) != (bytes == null));
  final String name;
  final String? file; // path on disk, streamed via openRead()
  final List<int>? bytes; // in-memory content (manifest / cheats)
  Stream<List<int>> get stream =>
      file != null ? File(file!).openRead() : Stream<List<int>>.value(bytes!);
  factory _ZipEntry.bytes(String name, List<int> bytes) =>
      _ZipEntry(name: name, bytes: bytes);
}

class _Crc32 {
  int _crc = 0xFFFFFFFF;
  void add(List<int> data) {
    for (final b in data) {
      _crc ^= (b & 0xff);
      for (var k = 0; k < 8; k++) {
        _crc = (_crc & 1) != 0 ? (_crc >> 1) ^ 0xEDB88320 : _crc >> 1;
      }
      _crc &= 0xFFFFFFFF;
    }
  }

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _CountingSink implements Sink<List<int>> {
  _CountingSink(this._io, this._onBytes);
  final IOSink _io;
  final void Function(int) _onBytes;
  @override
  void add(List<int> data) {
    _io.add(data);
    _onBytes(data.length);
  }

  @override
  void close() {}
}

class _CentralRecord {
  _CentralRecord(this.nameBytes, this.crc, this.comp, this.uncomp, this.localOffset);
  final List<int> nameBytes;
  final int crc;
  final int comp;
  final int uncomp;
  final int localOffset;
}

List<int> _u16(int v) => [(v & 0xff), (v >> 8) & 0xff];
List<int> _u32(int v) => [
      (v & 0xff),
      (v >> 8) & 0xff,
      (v >> 16) & 0xff,
      (v >> 24) & 0xff,
    ];

/// Writes [entries] to [out] as a ZIP in a single sequential pass. Local file
/// headers use the data-descriptor flag (bit 3) so CRC/sizes can be written
/// after the deflate stream without seeking — archive's decoder supports this.
Future<void> _streamZip(File out, List<_ZipEntry> entries,
    {BuildProgress? onProgress}) async {
  final iosink = out.openWrite();
  var position = 0;
  final central = <_CentralRecord>[];
  try {
    var done = 0;
    for (final e in entries) {
      final nameBytes = utf8.encode(e.name);
      final localOffset = position;
      final header = BytesBuilder();
      header.add(_u32(0x04034b50));
      header.add(_u16(20)); // version needed
      header.add(_u16(0x0808)); // UTF-8 (bit 11) + data descriptor (bit 3)
      header.add(_u16(8)); // deflate
      header.add(_u16(0)); // mod time
      header.add(_u16(0)); // mod date
      header.add(_u32(0)); // crc32 (filled in descriptor)
      header.add(_u32(0)); // compressed size (filled in descriptor)
      header.add(_u32(0)); // uncompressed size (filled in descriptor)
      header.add(_u16(nameBytes.length));
      header.add(_u16(0)); // extra
      header.add(nameBytes);
      final headerBytes = header.takeBytes();
      iosink.add(headerBytes);
      position += headerBytes.length;

      final crc = _Crc32();
      var uncomp = 0;
      var comp = 0;
      final counting = _CountingSink(iosink, (n) => comp += n);
      final bc = ByteConversionSink.from(counting);
      final deflateIn =
          ZLibCodec(raw: true).encoder.startChunkedConversion(bc);
      await for (final chunk in e.stream) {
        crc.add(chunk);
        uncomp += chunk.length;
        deflateIn.add(chunk);
      }
      deflateIn.close();
      await iosink.flush();

      final desc = BytesBuilder();
      desc.add(_u32(0x08074b50));
      desc.add(_u32(crc.value));
      desc.add(_u32(comp));
      desc.add(_u32(uncomp));
      final descBytes = desc.takeBytes();
      iosink.add(descBytes);
      position += comp + descBytes.length;

      central.add(_CentralRecord(nameBytes, crc.value, comp, uncomp, localOffset));
      done++;
      onProgress?.call(done, entries.length, '正在写入压缩包：${e.name}');
      await Future.delayed(Duration.zero);
    }

    final centralStart = position;
    for (final c in central) {
      final h = BytesBuilder();
      h.add(_u32(0x02014b50));
      h.add(_u16(20)); // version made by
      h.add(_u16(20)); // version needed
      h.add(_u16(0x0800)); // UTF-8 (central dir carries real sizes)
      h.add(_u16(8)); // deflate
      h.add(_u16(0)); // time
      h.add(_u16(0)); // date
      h.add(_u32(c.crc));
      h.add(_u32(c.comp));
      h.add(_u32(c.uncomp));
      h.add(_u16(c.nameBytes.length));
      h.add(_u16(0)); // extra
      h.add(_u16(0)); // comment
      h.add(_u16(0)); // disk number
      h.add(_u16(0)); // internal attrs
      h.add(_u32(0)); // external attrs
      h.add(_u32(c.localOffset));
      h.add(c.nameBytes);
      final hBytes = h.takeBytes();
      iosink.add(hBytes);
      position += hBytes.length;
    }
    final centralSize = position - centralStart;
    final eocd = BytesBuilder();
    eocd.add(_u32(0x06054b50));
    eocd.add(_u16(0));
    eocd.add(_u16(0));
    eocd.add(_u16(central.length));
    eocd.add(_u16(central.length));
    eocd.add(_u32(centralSize));
    eocd.add(_u32(centralStart));
    eocd.add(_u16(0));
    iosink.add(eocd.takeBytes());
    await iosink.flush();
  } finally {
    await iosink.close();
  }
}

/// IEEE 802.3 CRC32 (matches java.util.zip.CRC32), used for plain-ROM-zip
/// import where the manifest does not carry a precomputed CRC.
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
