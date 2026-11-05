import 'dart:io';

import 'cloud_save_models.dart';

/// 真实游戏存档的云端同步层（**上传**；恢复/冲突见后续实现）。
///
/// 本地存档布局（与 `EmulatorActivity` / `peer_server` 一致，全部在
/// `<filesDir>/saves/` 下，CRC 为 8 位大写十六进制）：
///
/// | 类型 | 本地文件 | 云端 save_name |
/// |---|---|---|
/// | 电池存档 | `<CRC>.sav` | `<CRC>.sav` |
/// | 自动存档 | `<CRC>.state` | `<CRC>.state` |
/// | 手动槽位 | `<CRC>.slotN.state` | `<CRC>.slotN.state` |
/// | 槽位缩略图 | `<CRC>.slotN.jpg` | `<CRC>.slotN.thumb.dat` |
///
/// 云端名与本地名尽量一致，恢复时可直接落盘；缩略图因为后端扩展名白名单
/// 不含 `.jpg`，改用 `.dat` 承载 JPEG 字节（后端不解析内容，只做白名单校验）。
/// `client_key` 用稳定串 `gp-save:<CRC>:<kind>[:<slot>]`，后端按
/// `user + client_key` 覆盖，因此同一槽位反复上传只更新一份 blob。
///
/// 街机（fbalpha/MAME）存档是 `<driver>.nv` / `<driver>.fs` / `<driver>.state`，
/// 其中 `.nv`/`.fs` 不在后端白名单内，本层暂不纳管（待白名单放开后再接）。
enum SaveKind { battery, auto, slot }

/// 一个存档槽位的身份：ROM 的 CRC + 种类（+ 手动槽号）。
class SaveKey {
  const SaveKey(this.crc, this.kind, [this.slot]);

  /// 8 位大写十六进制 CRC（与 `RomEntry.crcKey` 同源）。
  final String crc;
  final SaveKind kind;

  /// 仅 [SaveKind.slot] 使用（1 起）。
  final int? slot;

  String get id => '$crc:${kind.name}${slot == null ? '' : ':$slot'}';

  String get label => switch (kind) {
        SaveKind.battery => '电池存档',
        SaveKind.auto => '自动存档',
        SaveKind.slot => '槽位 $slot',
      };

  @override
  bool operator ==(Object other) =>
      other is SaveKey &&
      other.crc == crc &&
      other.kind == kind &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(crc, kind, slot);

  @override
  String toString() => id;
}

/// 本地存档文件（每个 key 一条）。
class LocalSave {
  LocalSave({
    required this.key,
    required this.file,
    required this.size,
    required this.modified,
    this.thumb,
  });

  final SaveKey key;
  final File file;
  final int size;
  final DateTime modified;

  /// 手动槽位的缩略图（`<CRC>.slotN.jpg`），可能为 null。
  final File? thumb;

  String get fileName => file.uri.pathSegments.last;
}

/// 云端存档（列表项 + 解析出的 [SaveKey]）。
class CloudSave {
  CloudSave({
    required this.summary,
    required this.key,
    required this.isThumb,
  });

  final CloudSaveSummary summary;
  final SaveKey key;

  /// true 表示这是槽位缩略图（`*.thumb.dat`），不是存档本体。
  final bool isThumb;

  String get id => summary.id;
  int get sizeBytes => summary.sizeBytes;
  DateTime get updatedAt => summary.updatedAt;
}

/// 本地 / 云端的差异（冲突策略直接基于它）。
///
/// 判定依据是时间戳：本地取文件 mtime，云端取 `updated_at`（上传时间）。
/// 恢复时会把落盘文件的 mtime 对齐到云端 `updated_at`，所以「已同步」是一个
/// 稳定状态，不会因为刚下载完就又被判成「本地较新」。
class SaveDiff {
  SaveDiff({
    required this.localOnly,
    required this.localNewer,
    required this.remoteNewer,
    required this.inSync,
    required this.cloudOnly,
  });

  /// 只在本机存在（从未上传）。
  final List<LocalSave> localOnly;

  /// 两边都有，但本地在上传之后又改过 → 应上传。
  final List<LocalSave> localNewer;

  /// 两边都有，但云端在本地文件之后更新过（别的设备上传）→ 应恢复。
  final List<({LocalSave local, CloudSave cloud})> remoteNewer;

  /// 内容与时间都对得上。
  final List<LocalSave> inSync;

  /// 只在云端存在（本机没有）→ 可恢复。
  final List<CloudSave> cloudOnly;

  int get pendingUpload => localOnly.length + localNewer.length;
  int get pendingDownload => remoteNewer.length + cloudOnly.length;
  bool get isClean => pendingUpload == 0 && pendingDownload == 0;
}

/// 上传结果。
class SaveUploadReport {
  SaveUploadReport();

  final List<SaveKey> uploaded = <SaveKey>[];
  final List<({SaveKey key, bool isThumb, Object error})> failed =
      <({SaveKey key, bool isThumb, Object error})>[];

  int get ok => uploaded.length;
  bool get hasError => failed.isNotEmpty;
}

/// 恢复结果。
class SaveRestoreReport {
  SaveRestoreReport();

  final List<SaveKey> restored = <SaveKey>[];

  /// 覆盖本地前生成的备份文件（`<存档>.bak-<时间戳>`）。
  final List<File> backups = <File>[];
  final List<({CloudSave item, bool isThumb, Object error})> failed =
      <({CloudSave item, bool isThumb, Object error})>[];

  int get ok => restored.length;
  bool get hasError => failed.isNotEmpty;
}

class CloudSaveSync {
  CloudSaveSync({required this.filesDir, required this.client});

  final String filesDir;
  final CloudSaveTransport client;

  Directory get _savesDir => Directory('$filesDir/saves');

  /// 某个槽位对应的本地存档路径（与 `EmulatorActivity` 命名一致）。
  File localFileFor(SaveKey key) {
    final crc = key.crc.toUpperCase();
    final name = switch (key.kind) {
      SaveKind.battery => '$crc.sav',
      SaveKind.auto => '$crc.state',
      SaveKind.slot => '$crc.slot${key.slot}.state',
    };
    return File('${_savesDir.path}/$name');
  }

  /// 某个槽位对应的本地缩略图路径（仅手动槽位有意义）。
  File thumbFileFor(SaveKey key) =>
      File('${_savesDir.path}/${key.crc.toUpperCase()}.slot${key.slot}.jpg');

  // ------------------------------------------------------------------ 命名

  static final RegExp _reBattery = RegExp(r'^([0-9A-Fa-f]{8})\.sav$');
  static final RegExp _reAuto = RegExp(r'^([0-9A-Fa-f]{8})\.state$');
  static final RegExp _reSlot = RegExp(r'^([0-9A-Fa-f]{8})\.slot(\d{1,2})\.state$');
  static final RegExp _reThumb =
      RegExp(r'^([0-9A-Fa-f]{8})\.slot(\d{1,2})\.thumb\.dat$');

  /// 云端 save_name（见类文档的表）。
  ///
  /// [isThumb] 只对手动槽位有意义（缩略图仅槽位有）。
  static String nameFor(SaveKey key, {bool isThumb = false}) {
    assert(!isThumb || key.kind == SaveKind.slot,
        '只有手动槽位才有缩略图');
    final crc = key.crc.toUpperCase();
    if (key.kind == SaveKind.battery) return '$crc.sav';
    if (key.kind == SaveKind.auto) return '$crc.state';
    if (isThumb) return '$crc.slot${key.slot}.thumb.dat';
    return '$crc.slot${key.slot}.state';
  }

  /// 稳定 client_key：后端按 (user, sha256(client_key+salt)) 覆盖同一份 blob。
  static String clientKeyFor(SaveKey key, {bool isThumb = false}) =>
      'gp-save:${key.crc.toUpperCase()}:${key.kind.name}'
      '${key.slot == null ? '' : ':${key.slot}'}${isThumb ? ':thumb' : ''}';

  /// 从云端文件名解析出槽位；非本层命名（如库备份 `*.json`）返回 null。
  static ({SaveKey key, bool isThumb})? parseCloudName(String name) {
    var m = _reThumb.firstMatch(name);
    if (m != null) {
      final slot = int.tryParse(m.group(2)!);
      if (slot == null) return null;
      return (
        key: SaveKey(m.group(1)!.toUpperCase(), SaveKind.slot, slot),
        isThumb: true,
      );
    }
    m = _reSlot.firstMatch(name);
    if (m != null) {
      final slot = int.tryParse(m.group(2)!);
      if (slot == null) return null;
      return (
        key: SaveKey(m.group(1)!.toUpperCase(), SaveKind.slot, slot),
        isThumb: false,
      );
    }
    m = _reBattery.firstMatch(name);
    if (m != null) {
      return (
        key: SaveKey(m.group(1)!.toUpperCase(), SaveKind.battery),
        isThumb: false,
      );
    }
    m = _reAuto.firstMatch(name);
    if (m != null) {
      return (
        key: SaveKey(m.group(1)!.toUpperCase(), SaveKind.auto),
        isThumb: false,
      );
    }
    return null;
  }

  // ------------------------------------------------------------------ 本地扫描

  /// 扫描 `<filesDir>/saves/` 的本层可托管存档。
  ///
  /// 规则与 `LibrarySearch.scanSaveKeysSync` 对齐：忽略空 `.sav`、
  /// `.preplay` 备份与其它扩展名；缩略图挂在对应槽位上。
  List<LocalSave> scanLocal() {
    final out = <LocalSave>[];
    List<FileSystemEntity> entities;
    try {
      if (!_savesDir.existsSync()) return out;
      entities = _savesDir.listSync(followLinks: false);
    } catch (_) {
      return out;
    }

    final thumbs = <String, File>{}; // '<CRC>:<slot>' -> jpg
    for (final e in entities) {
      if (e is! File) continue;
      final base = e.uri.pathSegments.last;
      final slotThumb = RegExp(r'^([0-9A-Fa-f]{8})\.slot(\d{1,2})\.jpg$')
          .firstMatch(base);
      if (slotThumb != null) {
        thumbs['${slotThumb.group(1)!.toUpperCase()}:${slotThumb.group(2)}'] = e;
      }
    }

    for (final e in entities) {
      if (e is! File) continue;
      final base = e.uri.pathSegments.last;
      SaveKey? key;
      var m = _reSlot.firstMatch(base);
      if (m != null) {
        final slot = int.tryParse(m.group(2)!);
        if (slot != null) {
          key = SaveKey(m.group(1)!.toUpperCase(), SaveKind.slot, slot);
        }
      } else {
        m = _reBattery.firstMatch(base);
        if (m != null) {
          key = SaveKey(m.group(1)!.toUpperCase(), SaveKind.battery);
        } else {
          m = _reAuto.firstMatch(base);
          if (m != null) {
            key = SaveKey(m.group(1)!.toUpperCase(), SaveKind.auto);
          }
        }
        // 空电池存档是核心初始化产物，不代表玩家进度。
        if (key != null && key.kind == SaveKind.battery) {
          try {
            if (e.lengthSync() <= 0) continue;
          } catch (_) {
            continue;
          }
        }
      }
      if (key == null) continue;

      int size;
      DateTime modified;
      try {
        final st = e.statSync();
        size = st.size;
        modified = st.modified;
      } catch (_) {
        continue;
      }
      out.add(LocalSave(
        key: key,
        file: e,
        size: size,
        modified: modified,
        thumb: thumbFor(key, thumbs),
      ));
    }

    out.sort((a, b) => a.key.id.compareTo(b.key.id));
    return out;
  }

  File? thumbFor(SaveKey key, [Map<String, File>? thumbs]) {
    if (key.kind != SaveKind.slot) return null;
    final map = thumbs ?? _scanThumbs();
    final f = map['${key.crc}:${key.slot}'];
    if (f == null) return null;
    try {
      return f.existsSync() ? f : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, File> _scanThumbs() {
    final thumbs = <String, File>{};
    try {
      if (!_savesDir.existsSync()) return thumbs;
      for (final e in _savesDir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final base = e.uri.pathSegments.last;
        final m =
            RegExp(r'^([0-9A-Fa-f]{8})\.slot(\d{1,2})\.jpg$').firstMatch(base);
        if (m == null) continue;
        thumbs['${m.group(1)!.toUpperCase()}:${m.group(2)}'] = e;
      }
    } catch (_) {/* 目录不可读 → 无缩略图 */}
    return thumbs;
  }

  // ------------------------------------------------------------------ 云端

  /// 拉取并过滤出「本层托管」的云端条目（库备份 `.json` 会被跳过）。
  Future<List<CloudSave>> listCloud() async {
    final all = await client.listSaves();
    final out = <CloudSave>[];
    for (final s in all) {
      final parsed = parseCloudName(s.saveName);
      if (parsed == null) continue;
      out.add(CloudSave(
        summary: s,
        key: parsed.key,
        isThumb: parsed.isThumb,
      ));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 本地与云端比对（时间戳三态 + 单边存在）。
  ///
  /// 容差取 30s：既吸收「上传耗时」（3M 带宽下几百 KB 也要几秒）与设备/服务器
  /// 之间的时钟漂移，又能识别出「玩完一局再存档」这种真实修改（通常间隔数分钟）。
  /// 代价是同步后 30 秒内的修改会先显示为已同步，下次再改就会正常提示。
  SaveDiff diff(List<LocalSave> local, List<CloudSave> cloud) {
    const tolerance = Duration(seconds: 30);
    final cloudByKey = <String, CloudSave>{};
    for (final c in cloud) {
      if (c.isThumb) continue;
      final prev = cloudByKey[c.key.id];
      if (prev == null || c.updatedAt.isAfter(prev.updatedAt)) {
        cloudByKey[c.key.id] = c;
      }
    }
    final localOnly = <LocalSave>[];
    final localNewer = <LocalSave>[];
    final remoteNewer = <({LocalSave local, CloudSave cloud})>[];
    final inSync = <LocalSave>[];
    for (final l in local) {
      final c = cloudByKey[l.key.id];
      if (c == null) {
        localOnly.add(l);
      } else if (l.modified.isAfter(c.updatedAt.add(tolerance))) {
        localNewer.add(l);
      } else if (c.updatedAt.isAfter(l.modified.add(tolerance))) {
        remoteNewer.add((local: l, cloud: c));
      } else {
        inSync.add(l);
      }
    }
    final localIds = local.map((e) => e.key.id).toSet();
    final cloudOnly = [
      for (final c in cloudByKey.values)
        if (!localIds.contains(c.key.id)) c,
    ];
    return SaveDiff(
      localOnly: localOnly,
      localNewer: localNewer,
      remoteNewer: remoteNewer,
      inSync: inSync,
      cloudOnly: cloudOnly,
    );
  }

  // ------------------------------------------------------------------ 上传

  /// 上传本地存档（含槽位缩略图）。[only] 为空表示全部。
  ///
  /// [onProgress] 参数为 (已完成, 总数)，用于 UI 进度提示。
  Future<SaveUploadReport> uploadLocal({
    required String passphrase,
    Iterable<SaveKey>? only,
    bool includeThumbs = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final report = SaveUploadReport();
    final filter = only == null ? null : {for (final k in only) k.id};
    final todo = [
      for (final l in scanLocal())
        if (filter == null || filter.contains(l.key.id)) l,
    ];
    final total = todo.fold<int>(
        0, (n, l) => n + 1 + (includeThumbs && l.thumb != null ? 1 : 0));

    var done = 0;
    for (final l in todo) {
      try {
        await client.uploadSave(
          saveName: nameFor(l.key),
          clientKey: clientKeyFor(l.key),
          file: l.file,
          passphrase: passphrase,
        );
        report.uploaded.add(l.key);
      } catch (e) {
        report.failed
            .add((key: l.key, isThumb: false, error: e));
      }
      done++;
      onProgress?.call(done, total);

      final thumb = includeThumbs ? l.thumb : null;
      if (thumb != null) {
        try {
          await client.uploadSave(
            saveName: nameFor(l.key, isThumb: true),
            clientKey: clientKeyFor(l.key, isThumb: true),
            file: thumb,
            passphrase: passphrase,
          );
        } catch (e) {
          report.failed
              .add((key: l.key, isThumb: true, error: e));
        }
        done++;
        onProgress?.call(done, total);
      }
    }
    return report;
  }

  // ------------------------------------------------------------------ 恢复

  /// 下载云端存档并落回 `saves/`（覆盖前先备份本地旧档）。
  ///
  /// [items] 为空表示恢复云端全部存档（每个槽位取最新一份）。
  /// 下载先写 `<目标>.part`，成功后才原子替换，避免断网/解密失败把本地存档写坏；
  /// 被覆盖的本地文件保留为 `<目标>.bak-<毫秒时间戳>`。
  Future<SaveRestoreReport> restore({
    required String passphrase,
    Iterable<CloudSave>? items,
    bool includeThumbs = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final report = SaveRestoreReport();
    final cloud = items?.toList() ?? await listCloud();

    // 同一槽位可能有多份（不同 clientKey / 多次上传），只取最新一份本体。
    final latestBody = <String, CloudSave>{};
    final latestThumb = <String, CloudSave>{};
    for (final c in cloud) {
      final bucket = c.isThumb ? latestThumb : latestBody;
      final prev = bucket[c.key.id];
      if (prev == null || c.updatedAt.isAfter(prev.updatedAt)) {
        bucket[c.key.id] = c;
      }
    }

    final bodies = latestBody.values.toList()
      ..sort((a, b) => a.key.id.compareTo(b.key.id));
    final thumbs = includeThumbs
        ? [
            for (final b in bodies)
              if (latestThumb[b.key.id] != null) latestThumb[b.key.id]!,
          ]
        : const <CloudSave>[];
    final total = bodies.length + thumbs.length;

    var done = 0;
    for (final item in bodies) {
      try {
        await _restoreOne(
          item,
          dest: localFileFor(item.key),
          passphrase: passphrase,
          report: report,
        );
        report.restored.add(item.key);
      } catch (e) {
        report.failed.add((item: item, isThumb: false, error: e));
      }
      done++;
      onProgress?.call(done, total);
    }
    for (final item in thumbs) {
      try {
        await _restoreOne(
          item,
          dest: thumbFileFor(item.key),
          passphrase: passphrase,
          report: report,
          backup: false,
        );
      } catch (e) {
        report.failed.add((item: item, isThumb: true, error: e));
      }
      done++;
      onProgress?.call(done, total);
    }
    return report;
  }

  Future<void> _restoreOne(
    CloudSave item, {
    required File dest,
    required String passphrase,
    required SaveRestoreReport report,
    bool backup = true,
  }) async {
    await dest.parent.create(recursive: true);
    final part = File('${dest.path}.part');
    try {
      final n = await client.downloadSave(item.id, dest: part, passphrase: passphrase);
      if (n <= 0 || !part.existsSync() || part.lengthSync() <= 0) {
        throw const FormatException('下载内容为空');
      }
      if (backup && dest.existsSync() && dest.lengthSync() > 0) {
        final bak = File(
            '${dest.path}.bak-${DateTime.now().millisecondsSinceEpoch}');
        dest.copySync(bak.path);
        report.backups.add(bak);
      }
      part.renameSync(dest.path);
      // 内容来自云端那次上传 → 把 mtime 对齐到云端 updated_at，
      // 否则刚落盘的文件会因为「比云端新」又被判成 localNewer（假冲突）。
      try {
        dest.setLastModifiedSync(item.updatedAt);
      } catch (_) {/* 个别文件系统不允许改 mtime，退化为按写入时间比较 */}
    } catch (_) {
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {/* 清理失败不影响原存档 */}
      rethrow;
    }
  }
}
